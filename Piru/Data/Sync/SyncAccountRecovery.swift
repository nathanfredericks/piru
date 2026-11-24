import CryptoKit
import Foundation
import Security

extension SyncAccount {
    nonisolated struct Root: Codable {
        let profileID: String
        let accountID: String
        let epoch: Int
        let label: String
        let anchor: SyncSDKToken
    }

    nonisolated struct RecoveryResponse: Decodable {
        let epoch: Int
        let recoveryBox: String
    }

    nonisolated struct RemoteProfile: Decodable {
        let profileID: String
        let anchorGrantID: String
        let epoch: Int
    }

    nonisolated struct Profiles: Decodable { let profiles: [RemoteProfile] }

    static func normalizedLabel(_ label: String) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120, trimmed.utf8.count <= 1024 else { throw Issue.invalidLabel }
        return trimmed
    }

    static func makeToken(url: String, profileID: String) -> SyncSDKToken {
        SyncSDKToken(
            url: url,
            profileID: profileID,
            grantID: UUID().uuidString.lowercased(),
            bearer: SyncWire.newBearer(),
            signPrivate: SyncWire.newSignPrivate(),
            boxPrivate: SyncWire.newBoxPrivate(),
        )
    }

    static func sealBytes(_ bytes: Data, key: SymmetricKey, context: String) throws -> String {
        let sealed = try AES.GCM.seal(bytes, using: key, authenticating: Data(context.utf8))
        guard let combined = sealed.combined else { throw SyncWireError.invalidEnvelope }
        return SyncWire.base64URL(combined)
    }

    static func openBytes(_ value: String, key: SymmetricKey, context: String) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: SyncWire.decodeBase64URL(value))
        return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
    }

    static func labelKey(_ keys: SyncProfileKeys) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: keys.indexKey),
            info: Data("piru-sync-grant-label-v1".utf8),
            outputByteCount: 32,
        )
    }

    nonisolated struct GrantLabel: Codable {
        let label: String
        let proof: String
    }

    static func labelContext(profile: String, id: String, scope: SyncGrantScope, sign: String, box: String) -> String {
        ["piru-sync-grant-label-v1", profile, id, scope.rawValue, sign, box].joined(separator: "\n")
    }

    /// HPKE base mode allows anyone to wrap to a public recipient. The grant's
    /// signature binds its first received index key to the keys in its local token.
    static func labelProof(_ context: String, indexKey: Data) -> Data {
        let digest = SyncWire.base64URL(Data(SHA256.hash(data: indexKey)))
        return Data((context + "\n" + digest).utf8)
    }

    static func makeGrant(
        _ token: SyncSDKToken,
        scope: SyncGrantScope,
        label: String,
        epoch: Int,
        keys: SyncProfileKeys,
    ) throws -> SyncGrant {
        let signPublic = try SyncWire.signPublic(for: token.signPrivate)
        let boxPublic = try SyncWire.boxPublic(for: token.boxPrivate)
        let context = labelContext(profile: token.profileID, id: token.grantID, scope: scope, sign: signPublic, box: boxPublic)
        let signer = try P256.Signing.PrivateKey(rawRepresentation: SyncWire.bytes(token.signPrivate, count: 32))
        let proof = try signer.signature(for: labelProof(context, indexKey: keys.indexKey))
        let metadata = GrantLabel(label: label, proof: SyncWire.base64URL(proof.rawRepresentation))
        let labelBox = try sealBytes(JSONEncoder().encode(metadata), key: labelKey(keys), context: context)
        return try SyncGrant(
            id: token.grantID,
            scope: scope,
            signPublic: signPublic,
            boxPublic: boxPublic,
            labelBox: labelBox,
            wrapped: SyncWire.wrap(
                keys,
                profileID: token.profileID,
                grantID: token.grantID,
                epoch: epoch,
                boxPublic: boxPublic,
            ),
        )
    }

    static func label(_ grant: SyncGrant, profileID: String, keys: SyncProfileKeys) throws -> String {
        try SyncWire.checkID(grant.id)
        let context = labelContext(
            profile: profileID,
            id: grant.id,
            scope: grant.scope,
            sign: grant.signPublic,
            box: grant.boxPublic,
        )
        let bytes = try openBytes(grant.labelBox, key: labelKey(keys), context: context)
        let value = try JSONDecoder().decode(GrantLabel.self, from: bytes)
        let verifier = try P256.Signing.PublicKey(x963Representation: SyncWire.bytes(grant.signPublic, count: 65))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: SyncWire.bytes(value.proof, count: 64))
        guard verifier.isValidSignature(signature, for: labelProof(context, indexKey: keys.indexKey))
        else { throw SyncWireError.invalidSignature }
        return value.label
    }

    static func recoveryKey(_ code: String) throws -> SymmetricKey {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix("piru-r1."), let raw = try? SyncWire.bytes(String(code.dropFirst(8)), count: 32)
        else { throw Issue.recovery }
        return SymmetricKey(data: raw)
    }

    static func recoveryContext(_ account: String, _ profile: String, _ epoch: Int) -> String {
        ["piru-sync-recovery-v1", account, profile, String(epoch)].joined(separator: "\n")
    }

    static func sealRoot(_ root: Root, code: String) throws -> String {
        try sealBytes(
            JSONEncoder().encode(root),
            key: recoveryKey(code),
            context: recoveryContext(root.accountID, root.profileID, root.epoch),
        )
    }

    func recoveryRoot(_ p: String, session: Session, code: String) async throws -> Root {
        let response: RecoveryResponse = try await accountRequest("GET", ["profiles", p, "recovery"], session: session)
        do {
            let data = try Self.openBytes(
                response.recoveryBox,
                key: Self.recoveryKey(code),
                context: Self.recoveryContext(session.accountID, p, response.epoch),
            )
            let root = try JSONDecoder().decode(Root.self, from: data)
            guard root.profileID == p, root.accountID == session.accountID, root.epoch == response.epoch,
                  root.anchor.profileID == p, try root.anchor.url == origin else { throw Issue.recovery }
            return root
        } catch { throw Issue.recovery }
    }

    func codeKey(_ p: String, _ account: String) throws -> String { try origin + "/account/" + account + "/" + p }

    func findCode(_ p: String, _ account: String) throws -> String? {
        let path = try codeKey(p, account)
        if let local = try codes.read(String.self, at: path) { return local }
        return try cloudCodes.read(String.self, at: path)
    }

    func saveCode(_ code: String, profileID: String, accountID: String) throws {
        let path = try codeKey(profileID, accountID)
        try codes.write(code, at: path)
        do {
            try cloudCodes.write(code, at: path)
        } catch let SyncAccountKeychain.Failure.unavailable(status) where status != errSecNotAvailable {
            throw SyncAccountKeychain.Failure.unavailable(status)
        } catch {
            // The local and portable recovery codes also work when iCloud Keychain is unavailable.
        }
    }

    func recoveryCode(for localProfileID: UUID) throws -> String {
        guard let c = try boundConnection(for: localProfileID),
              let code = try findCode(c.profileID, c.accountID) else { throw Issue.recovery }
        return code
    }

    func journals() async throws -> [Journal] {
        let session = try readSession()
        let list: Profiles = try await accountRequest("GET", ["profiles"], session: session)
        var results: [Journal] = []
        for p in list.profiles {
            try SyncWire.checkID(p.profileID)
            var label = p.profileID
            if let code = try findCode(p.profileID, session.accountID) {
                do {
                    label = try await recoveryRoot(p.profileID, session: session, code: code).label
                } catch Issue.recovery {
                    // A separately saved recovery code can still be entered.
                }
            }
            results.append(Journal(id: p.profileID, label: label))
        }
        guard try readSession() == session else { throw Issue.changed }
        return results
    }
}
