import CryptoKit
import Foundation

nonisolated struct SyncEnvelope: Codable, Equatable, Sendable {
    let profileID: String
    let docID: String
    let opID: String
    let grantID: String
    let epoch: Int
    let nonce: String
    let ciphertext: String
    let signature: String
}

nonisolated enum SyncGrantScope: String, Codable, Sendable {
    case owner
    case read
    case write
}

nonisolated struct SyncWrappedKey: Codable, Equatable, Sendable {
    let enc: String
    let ct: String
}

nonisolated struct SyncGrant: Codable, Equatable, Sendable {
    let id: String
    let scope: SyncGrantScope
    let signPublic: String
    let boxPublic: String
    let labelBox: String
    var wrapped: SyncWrappedKey?
    var revoked: Bool?
}

nonisolated struct SyncChange: Codable, Equatable, Sendable {
    let seq: Int
    let envelope: SyncEnvelope
}

nonisolated struct SyncChangesPage: Codable, Equatable, Sendable {
    let changes: [SyncChange]
    let cursor: Int
    let hasMore: Bool
}

nonisolated struct SyncReceipt: Codable, Equatable, Sendable {
    let seq: Int
}

nonisolated struct SyncGrantsPage: Codable, Equatable, Sendable {
    let epoch: Int
    let grants: [SyncGrant]
    var anchorGrantID: String?
}

nonisolated struct SyncProfileKeys: Equatable, Sendable {
    let contentKey: Data
    let indexKey: Data

    init(contentKey: Data, indexKey: Data) throws {
        guard contentKey.count == 32, indexKey.count == 32 else { throw SyncWireError.invalidKey }
        self.contentKey = contentKey
        self.indexKey = indexKey
    }

    private init() {
        contentKey = SyncWire.random32()
        indexKey = SyncWire.random32()
    }

    static func generate() -> Self { Self() }
}

nonisolated struct SyncSDKToken: Codable, Equatable, Sendable {
    let url: String
    let profileID: String
    let grantID: String
    let bearer: String
    let signPrivate: String
    let boxPrivate: String

    func encoded() throws -> String {
        try validate()
        return try "piru1." + SyncWire.base64URL(JSONEncoder().encode(self))
    }

    static func decode(_ token: String) throws -> Self {
        guard token.hasPrefix("piru1.") else { throw SyncWireError.invalidToken }
        let data = try SyncWire.decodeBase64URL(String(token.dropFirst("piru1.".count)))
        let token = try JSONDecoder().decode(Self.self, from: data)
        try token.validate()
        return token
    }

    private func validate() throws {
        try SyncWire.checkID(profileID)
        try SyncWire.checkID(grantID)
        guard let components = URLComponents(string: url),
              let scheme = components.scheme,
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)),
              ["", "/", "/v1", "/v1/"].contains(components.path), components.fragment == nil, components.query == nil
        else { throw SyncWireError.invalidToken }
        _ = try SyncWire.bytes(bearer, count: 32)
        _ = try SyncWire.signPublic(for: signPrivate)
        _ = try SyncWire.boxPublic(for: boxPrivate)
    }
}

nonisolated enum SyncWireError: Error, Equatable {
    case invalidBase64
    case invalidID
    case invalidKey
    case invalidEnvelope
    case invalidSignature
    case invalidToken
    case wrongDocument
}

nonisolated enum SyncWire {
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ value: String) throws -> Data {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard !value.isEmpty, let data = Data(base64Encoded: base64), base64URL(data) == value else {
            throw SyncWireError.invalidBase64
        }
        return data
    }

    static func bytes(_ value: String, count: Int) throws -> Data {
        let data = try decodeBase64URL(value)
        guard data.count == count else { throw SyncWireError.invalidKey }
        return data
    }

    static func checkID(_ id: String) throws {
        guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else {
            throw SyncWireError.invalidID
        }
    }

    static func checkEpoch(_ epoch: Int) throws {
        guard (1 ... 9_007_199_254_740_991).contains(epoch) else { throw SyncWireError.invalidEnvelope }
    }

    static func random32() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    static func newBearer() -> String { base64URL(random32()) }
    static func newSignPrivate() -> String { base64URL(P256.Signing.PrivateKey().rawRepresentation) }
    static func newBoxPrivate() -> String { base64URL(P256.KeyAgreement.PrivateKey().rawRepresentation) }

    static func signPublic(for privateKey: String) throws -> String {
        let key = try P256.Signing.PrivateKey(rawRepresentation: bytes(privateKey, count: 32))
        return base64URL(key.publicKey.x963Representation)
    }

    static func boxPublic(for privateKey: String) throws -> String {
        let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: bytes(privateKey, count: 32))
        return base64URL(key.publicKey.x963Representation)
    }

    private static func keyInfo(profileID: String, grantID: String, epoch: Int) throws -> Data {
        try checkID(profileID)
        try checkID(grantID)
        try checkEpoch(epoch)
        return Data("piru-sync-key-v1\n\(profileID)\n\(grantID)\n\(epoch)".utf8)
    }

    static func wrap(
        _ keys: SyncProfileKeys,
        profileID: String,
        grantID: String,
        epoch: Int,
        boxPublic: String,
    ) throws -> SyncWrappedKey {
        let recipient = try P256.KeyAgreement.PublicKey(x963Representation: bytes(boxPublic, count: 65))
        let info = try keyInfo(profileID: profileID, grantID: grantID, epoch: epoch)
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: .P256_SHA256_AES_GCM_256, info: info)
        let sealed = try sender.seal(keys.contentKey + keys.indexKey)
        return SyncWrappedKey(enc: base64URL(sender.encapsulatedKey), ct: base64URL(sealed))
    }

    static func unwrap(
        _ wrap: SyncWrappedKey,
        profileID: String,
        grantID: String,
        epoch: Int,
        boxPrivate: String,
    ) throws -> SyncProfileKeys {
        let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: bytes(boxPrivate, count: 32))
        let info = try keyInfo(profileID: profileID, grantID: grantID, epoch: epoch)
        var recipient = try HPKE.Recipient(
            privateKey: key,
            ciphersuite: .P256_SHA256_AES_GCM_256,
            info: info,
            encapsulatedKey: bytes(wrap.enc, count: 65),
        )
        let data = try recipient.open(bytes(wrap.ct, count: 80))
        return try SyncProfileKeys(contentKey: data.prefix(32), indexKey: data.dropFirst(32))
    }
}
