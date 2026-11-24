import Foundation
import Testing
@testable import Piru

@Suite("Sync document and signed wire format")
struct SyncWireTests {
    let key = SyncRecordKey(kind: "dose", recordID: "00000000-0000-4000-8000-000000000001")
    let profile = "00000000-0000-4000-8000-000000000002"
    let grantID = "00000000-0000-4000-8000-000000000003"
    let op = "00000000-0000-4000-8000-000000000004"
    let cup = #"{"amount":1,"unit":"cup"}"#
    let gram = #"{"amount":70,"unit":"g"}"#
    let milligram = #"{"amount":90,"unit":"mg"}"#

    private func edit(_ base: Data?, _ before: SyncFields?, _ after: SyncFields?) throws -> Data {
        try SyncDocument.localEdit(baseDoc: base, key: key, before: before, after: after)
    }

    @Test
    func `independent and overlapping edits`() throws {
        let original = ["dose": cup, "note": #""old""#, "time": "1"]
        let leftFields = ["dose": gram, "note": #""new""#, "time": "1"]
        let rightFields = ["dose": milligram, "note": #""old""#, "time": "2"]
        let base = try edit(nil, nil, original)
        let left = try edit(base, original, leftFields)
        let right = try edit(base, original, rightFields)
        let merged = try SyncDocument.merge(left, right)
        let projection = try SyncDocument.fields(merged)
        let result = try #require(projection)
        #expect(try SyncDocument.fields(SyncDocument.merge(right, left)) == result)
        #expect(try SyncDocument.fields(SyncDocument.merge(merged, left)) == result)
        #expect(result["note"] == leftFields["note"])
        #expect(result["time"] == "2")
        #expect([gram, milligram].contains(result["dose"] ?? ""))
        #expect(try SyncDocument.conflicts(merged) == ["dose": [gram, milligram].sorted()])

        var next = result
        next["dose"] = cup
        let later = try edit(merged, result, next)
        #expect(try SyncDocument.fields(SyncDocument.merge(later, right)) == next)
        #expect(try SyncDocument.conflicts(later).isEmpty)
        let history = try SyncDocument.history(later)
        #expect(history.contains { $0.fields == leftFields })
        #expect(history.contains { $0.fields == rightFields })
        #expect(history.contains { $0.fields == next && $0.parents.count == 2 })
    }

    @Test
    func `canonicalized local baseline preserves untouched remote registers`() throws {
        let remoteTuple = #"{"unit":"mg","amount":70}"#
        let canonicalTuple = #"{"amount":70,"unit":"mg"}"#
        let original: SyncFields = ["dose": remoteTuple, "note": "null", "futureField": "true"]
        let base = try edit(nil, nil, original)
        let localBefore = ["dose": canonicalTuple, "note": "null"]
        var localAfter = localBefore
        localAfter["note"] = #""breakfast""#
        let local = try edit(base, localBefore, localAfter)
        #expect(try SyncDocument.fields(local)?["dose"] == remoteTuple)

        var remoteAfter = original
        remoteAfter["dose"] = milligram
        let remote = try edit(base, original, remoteAfter)
        let merged = try SyncDocument.merge(local, remote)
        #expect(try SyncDocument.fields(merged) == ["dose": milligram, "note": #""breakfast""#, "futureField": "true"])
        #expect(try SyncDocument.conflicts(merged).isEmpty)
    }

    @Test
    func `offline delete and edit keep both historical results after a later receipt`() throws {
        let original = ["dose": cup]
        let base = try edit(nil, nil, original)
        let tombstone = try edit(base, original, nil)
        let otherEdit = try edit(base, original, ["dose": gram])
        let joined = try SyncDocument.receive(otherEdit, previous: tombstone)
        #expect(!joined.projectionChanged)
        #expect(joined.fields == nil)
        let point = try #require(joined.mergePoints.first)
        let detail = try SyncDocument.mergeDetail(joined.document, heads: point)
        #expect(detail.versions.contains(nil))
        #expect(detail.versions.contains(["dose": gram]))
        #expect(detail.result == nil)
        #expect(try SyncDocument.receive(otherEdit, previous: joined.document).mergePoints.isEmpty)
    }

    @Test
    func `first receipt of a later causal edit recovers the earlier merge`() throws {
        let original = ["dose": cup]
        let base = try edit(nil, nil, original)
        let left = try edit(base, original, ["dose": gram])
        let right = try edit(base, original, ["dose": milligram])
        let merged = try SyncDocument.merge(left, right)
        let result = try SyncDocument.fields(merged)
        let later = try edit(merged, result, ["dose": cup])
        let restored = try SyncDocument.receive(later, previous: nil)
        let point = try #require(restored.mergePoints.first)
        let detail = try SyncDocument.mergeDetail(restored.document, heads: point)
        #expect(detail.result == result)
        #expect(detail.conflicts["dose"] == [gram, milligram].sorted())
        #expect(restored.fields == original)
    }

    @Test
    func `bootstrap and deletion`() throws {
        let left = try edit(nil, nil, ["note": #""local""#])
        let right = try edit(nil, nil, ["dose": cup])
        let joined = try SyncDocument.merge(left, right)
        #expect(try SyncDocument.fields(joined) == ["note": #""local""#, "dose": cup])
        let removed = try edit(left, ["note": #""local""#], nil)
        let deleted = try SyncDocument.merge(removed, joined)
        #expect(try SyncDocument.fields(deleted) == nil)
        #expect(try SyncDocument.fields(SyncDocument.merge(joined, removed)) == nil)
        #expect(try SyncDocument.fields(edit(deleted, nil, ["dose": gram])) == nil)
        #expect(try SyncDocument.history(deleted).contains { $0.fields == nil })
        #expect(try SyncDocument.history(deleted).contains { $0.fields == ["dose": cup] })
        let other = try SyncDocument.localEdit(
            baseDoc: nil,
            key: SyncRecordKey(kind: "session", recordID: key.recordID),
            before: nil,
            after: [:],
        )
        #expect(throws: SyncDocumentError.self) { try SyncDocument.merge(deleted, other) }
    }

    @Test
    func `fields are JSON and reserved keys are immutable`() throws {
        for field in ["_deleted", "recordID", "kind", "__proto__", "constructor", "prototype", ""] {
            #expect(throws: SyncDocumentError.self) { try edit(nil, nil, [field: "true"]) }
        }
        #expect(throws: SyncDocumentError.self) { try edit(nil, nil, ["note": "unterminated"]) }
        let original = ["note": "null", "tag": #""café""#]
        let base = try edit(nil, nil, original)
        #expect(try SyncDocument.fields(edit(base, original, ["note": "null"])) == ["note": "null"])
        #expect(try SyncDocument.key(base) == key)
    }

    @Test
    func `hpke binds epoch profile and recipient`() throws {
        let keys = SyncProfileKeys.generate()
        let secret = SyncWire.newBoxPrivate()
        let wrapped = try SyncWire.wrap(
            keys,
            profileID: profile,
            grantID: grantID,
            epoch: 7,
            boxPublic: SyncWire.boxPublic(for: secret),
        )
        #expect(try SyncWire.decodeBase64URL(wrapped.enc).count == 65)
        #expect(try SyncWire.decodeBase64URL(wrapped.ct).count == 80)
        #expect(try SyncWire.unwrap(wrapped, profileID: profile, grantID: grantID, epoch: 7, boxPrivate: secret) == keys)
        for (p, g, e, s) in [
            (op, grantID, 7, secret),
            (profile, op, 7, secret),
            (profile, grantID, 6, secret),
            (profile, grantID, 7, SyncWire.newBoxPrivate()),
        ] {
            #expect(throws: (any Error).self) { try SyncWire.unwrap(wrapped, profileID: p, grantID: g, epoch: e, boxPrivate: s) }
        }
    }

    @Test
    func `envelope binds signer header ciphertext and index`() throws {
        let keys = SyncProfileKeys.generate()
        let secret = SyncWire.newSignPrivate()
        let grant = try SyncGrant(
            id: grantID,
            scope: .write,
            signPublic: SyncWire.signPublic(for: secret),
            boxPublic: SyncWire.boxPublic(for: SyncWire.newBoxPrivate()),
            labelBox: "AQ",
        )
        let doc = try edit(nil, nil, ["dose": gram])
        let envelope = try SyncWire.seal(doc, profileID: profile, opID: op, grantID: grantID, epoch: 2, keys: keys, signPrivate: secret)
        #expect(try SyncWire.open(envelope, profileID: profile, grant: grant, keys: keys) == doc)
        #expect(try SyncWire.decodeBase64URL(envelope.nonce).count == 12)
        #expect(try SyncWire.decodeBase64URL(envelope.ciphertext).count == doc.count + 16)
        #expect(try SyncWire.decodeBase64URL(envelope.signature).count == 64)
        let sealedAgain = try SyncWire.seal(doc, profileID: profile, opID: op, grantID: grantID, epoch: 2, keys: keys, signPrivate: secret)
        #expect(sealedAgain.nonce != envelope.nonce)
        #expect(sealedAgain.docID == envelope.docID)

        let bytes = try JSONEncoder().encode(envelope)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for (name, replacement) in [
            ("profileID", op),
            ("grantID", op),
            ("opID", profile),
            ("docID", SyncWire.newBearer()),
            ("nonce", SyncWire.base64URL(Data(repeating: 0, count: 12))),
            ("ciphertext", envelope.ciphertext + "AA"),
            ("signature", envelope.signature + "="),
        ] {
            var changed = object
            changed[name] = replacement
            let bad = try JSONDecoder().decode(SyncEnvelope.self, from: JSONSerialization.data(withJSONObject: changed))
            #expect(throws: (any Error).self) { try SyncWire.open(bad, profileID: profile, grant: grant, keys: keys) }
        }
        var changed = object
        changed["epoch"] = 3
        let bad = try JSONDecoder().decode(SyncEnvelope.self, from: JSONSerialization.data(withJSONObject: changed))
        #expect(throws: SyncWireError.invalidSignature) { try SyncWire.open(bad, profileID: profile, grant: grant, keys: keys) }
        let wrongIndex = try SyncProfileKeys(contentKey: keys.contentKey, indexKey: SyncWire.random32())
        #expect(throws: SyncWireError.wrongDocument) { try SyncWire.open(envelope, profileID: profile, grant: grant, keys: wrongIndex) }
        let reader = SyncGrant(id: grant.id, scope: .read, signPublic: grant.signPublic, boxPublic: grant.boxPublic, labelBox: grant.labelBox)
        #expect(throws: SyncWireError.invalidEnvelope) { try SyncWire.open(envelope, profileID: profile, grant: reader, keys: keys) }
    }

    @Test
    func `canonical encoding and compound token`() throws {
        for invalid in ["", "YQ==", "YR", "/w", "+w", "a\nb", "A"] {
            #expect(throws: SyncWireError.invalidBase64) { try SyncWire.decodeBase64URL(invalid) }
        }
        #expect(try SyncWire.decodeBase64URL("_w") == Data([255]))
        let token = SyncSDKToken(
            url: "https://example.test/v1",
            profileID: profile,
            grantID: grantID,
            bearer: SyncWire.newBearer(),
            signPrivate: SyncWire.newSignPrivate(),
            boxPrivate: SyncWire.newBoxPrivate(),
        )
        let encoded = try token.encoded()
        #expect(encoded.hasPrefix("piru1."))
        #expect(try SyncSDKToken.decode(encoded) == token)
        #expect(throws: SyncWireError.self) { try SyncSDKToken.decode("piru2.test") }
        #expect(try SyncWire.decodeBase64URL(token.bearer).count == 32)
        #expect(throws: SyncWireError.invalidID) { try SyncWire.checkID("AAAAAAAA-0000-0000-0000-000000000000") }
    }

    @Test @MainActor
    func `grant label authenticates scope and both public keys`() throws {
        let token = SyncAccount.makeToken(url: "https://example.test/v1", profileID: profile)
        let keys = SyncProfileKeys.generate()
        let grant = try SyncAccount.makeGrant(token, scope: .read, label: "Weekly summary", epoch: 1, keys: keys)
        #expect(try SyncAccount.label(grant, profileID: profile, keys: keys) == "Weekly summary")

        let otherSigner = try SyncWire.signPublic(for: SyncWire.newSignPrivate())
        let otherRecipient = try SyncWire.boxPublic(for: SyncWire.newBoxPrivate())
        let substitutions: [(SyncGrantScope, String, String)] = [
            (.write, grant.signPublic, grant.boxPublic),
            (grant.scope, otherSigner, grant.boxPublic),
            (grant.scope, grant.signPublic, otherRecipient),
        ]
        for (scope, signPublic, boxPublic) in substitutions {
            let changed = SyncGrant(
                id: grant.id, scope: scope, signPublic: signPublic, boxPublic: boxPublic,
                labelBox: grant.labelBox, wrapped: grant.wrapped,
            )
            #expect(throws: (any Error).self) { try SyncAccount.label(changed, profileID: profile, keys: keys) }
        }
    }

    /// Produced by the v1 TypeScript SDK with @automerge/automerge 3.5, WebCrypto and @hpke/core.
    @Test
    func `typescript interoperability`() throws {
        let boxPrivate = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE"
        let grant = SyncGrant(
            id: grantID,
            scope: .owner,
            signPublic: "BHzyexiNA09-ilI4AwS1GsPAiWnid_IbNaYLSPxHZpl4B3dVENuO0EApPZrGn3Qw27p9reY86YIpngS3nSJ4c9E",
            boxPublic: "BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU",
            labelBox: "AQ",
        )
        let wrap = SyncWrappedKey(
            enc: "BCnZrwf7RVaiGyu8DciBXN8r11aVBgSyFOoCUwi5ePCyxtLTDmLaRrDpj7q-80TvXR8UoxBHXvcYQl-VCjuW4Q8",
            ct: "4ayrv6hOPYDVBOinrN1uTPdleklI6xiMglzwVp7_xxvvb9ey0hKEDwQqtjFDsvjTVCyAc5Q7F47SAVhUpPjdoTWuv3uacOIw7O4IC9JXiLQ",
        )
        let keys = try SyncWire.unwrap(wrap, profileID: profile, grantID: grantID, epoch: 1, boxPrivate: boxPrivate)
        #expect(keys.contentKey == Data(0 ..< 32))
        #expect(keys.indexKey == Data(32 ..< 64))
        let envelope = SyncEnvelope(
            profileID: profile,
            docID: "Xfm9t2ZrowKUpCYeYHr3jGStaIBAhEcOXktb89KJ5qE",
            opID: op,
            grantID: grantID,
            epoch: 1,
            nonce: "oXlbXyFTb6PcDXMo",
            ciphertext:
            "PUPHPEvBYWXbvmimQxVtUTBBBipcX8bpS1k57LpLrH-8Fx33dSRzufR-tXTmZ0VSBdD9Oy3VD9edXLi5F-tGlku4Dh" +
                "8uhVGisi2XXD8gTUjEvCtSEgvvjmHW8Giup3qi2yEWBafPmXDUUqQlKj4vS_OfRQhjkhWnYFsBVtkI4dnKAoheX5nn" +
                "pbkh1_nPRcdM5e2hjDmdgC6kYuMM-f9bmNBrGa0632lx1jWdvavtQFvcTt7VdOTlgnehSE_61xUM18an3hYUn9Z0Py" +
                "gJaYv2G8xp4xWVm5sc5GRnp6FyiWf3tF1468xSSpFNDY2RFQdgH1WxhFY",
            signature: "gSL9DJiq9Lofjzw3ZcaodkCQnpTM3gJ-r68MBwaZ8VkeZ0Owil1SK74CqW7-yDw6KDA48-AM9RFaFch9Z_9JJw",
        )
        let document = try SyncWire.open(envelope, profileID: profile, grant: grant, keys: keys)
        #expect(try SyncDocument.key(document) == key)
        #expect(try SyncDocument.fields(document) == ["dose": #"{"amount":2,"unit":"cup"}"#, "note": #""from JS""#])
    }
}
