import CryptoKit
import Foundation

nonisolated extension SyncWire {
    static func docID(_ key: SyncRecordKey, indexKey: Data) throws -> String {
        try SyncDocument.validate(key)
        guard indexKey.count == 32 else { throw SyncWireError.invalidKey }
        let identity = Data("\(key.kind)\n\(key.recordID)".utf8)
        return base64URL(Data(HMAC<SHA256>.authenticationCode(for: identity, using: SymmetricKey(data: indexKey))))
    }

    private static func aad(profileID: String, docID: String, opID: String, grantID: String, epoch: Int) throws -> String {
        try checkID(profileID)
        try checkID(opID)
        try checkID(grantID)
        try checkEpoch(epoch)
        _ = try bytes(docID, count: 32)
        return ["piru-sync-v1", profileID, docID, opID, grantID, String(epoch)].joined(separator: "\n")
    }

    static func seal(
        _ snapshot: Data,
        profileID: String,
        opID: String,
        grantID: String,
        epoch: Int,
        keys: SyncProfileKeys,
        signPrivate: String,
    ) throws -> SyncEnvelope {
        let documentID = try docID(SyncDocument.key(snapshot), indexKey: keys.indexKey)
        let header = try aad(profileID: profileID, docID: documentID, opID: opID, grantID: grantID, epoch: epoch)
        let sealed = try AES.GCM.seal(snapshot, using: SymmetricKey(data: keys.contentKey), authenticating: Data(header.utf8))
        let nonce = sealed.nonce.withUnsafeBytes { base64URL(Data($0)) }
        let ciphertext = base64URL(sealed.ciphertext + sealed.tag)
        let signingKey = try P256.Signing.PrivateKey(rawRepresentation: bytes(signPrivate, count: 32))
        let signature = try signingKey.signature(for: Data("\(header)\n\(nonce)\n\(ciphertext)".utf8))
        return SyncEnvelope(
            profileID: profileID,
            docID: documentID,
            opID: opID,
            grantID: grantID,
            epoch: epoch,
            nonce: nonce,
            ciphertext: ciphertext,
            signature: base64URL(signature.rawRepresentation),
        )
    }

    /// Supply the signer's directory entry and content key from the envelope's epoch.
    static func open(_ envelope: SyncEnvelope, profileID: String, grant: SyncGrant, keys: SyncProfileKeys) throws -> Data {
        guard profileID == envelope.profileID, grant.id == envelope.grantID, grant.scope != .read, grant.revoked != true else {
            throw SyncWireError.invalidEnvelope
        }
        let header = try aad(
            profileID: profileID,
            docID: envelope.docID,
            opID: envelope.opID,
            grantID: grant.id,
            epoch: envelope.epoch,
        )
        let verifier = try P256.Signing.PublicKey(x963Representation: bytes(grant.signPublic, count: 65))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: bytes(envelope.signature, count: 64))
        let signed = Data("\(header)\n\(envelope.nonce)\n\(envelope.ciphertext)".utf8)
        guard verifier.isValidSignature(signature, for: signed) else { throw SyncWireError.invalidSignature }
        let ciphertext = try decodeBase64URL(envelope.ciphertext)
        guard ciphertext.count > 16 else { throw SyncWireError.invalidEnvelope }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: bytes(envelope.nonce, count: 12)),
            ciphertext: ciphertext.dropLast(16),
            tag: ciphertext.suffix(16),
        )
        let snapshot = try AES.GCM.open(box, using: SymmetricKey(data: keys.contentKey), authenticating: Data(header.utf8))
        guard try docID(SyncDocument.key(snapshot), indexKey: keys.indexKey) == envelope.docID else {
            throw SyncWireError.wrongDocument
        }
        return snapshot
    }
}
