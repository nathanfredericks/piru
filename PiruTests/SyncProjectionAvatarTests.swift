import Foundation
import Security
import SwiftData
import Testing
@testable import Piru

@MainActor
@Suite("Avatar sync projection")
struct SyncProjectionAvatarTests {
    private let metadata = SyncRecordKey(kind: SyncProjection.metadataKind, id: SyncProjection.singletonID)

    private func select(_ bytes: Data?, ext: String = "jpg", in directory: ProfileDirectory) throws -> [SyncRecordKey: SyncFields] {
        var owner = directory.owner
        owner.avatar.photo = try bytes.map { try ProfilePhotoStore.write($0, fileExtension: ext, in: directory.containerURL) }
        try directory.update(owner)
        return try SyncProjection.metadataRecords(profileID: owner.id, directory: directory)
    }

    private func deliver(_ key: SyncRecordKey, _ fields: SyncFields?, to directory: ProfileDirectory) throws {
        try SyncProjection.apply(key, fields: fields, in: ModelContext(directory.activeContainer), profileID: directory.owner.id, directory: directory)
    }

    @Test(arguments: [true, false])
    func `asset and reference survive either delivery order and an avatar sweep`(assetFirst: Bool) throws {
        let (source, sourceURL) = try makeScratchProfileDirectory()
        let (target, targetURL) = try makeScratchProfileDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let bytes = Data([251, 255, 0])
        let records = try select(bytes, in: source)
        let asset = try #require(records.keys.first { $0.kind == SyncProjection.avatarAssetKind })
        #expect(records[asset]?["bytes"] == #""-_8A""#)
        let first = assetFirst ? asset : metadata
        let second = assetFirst ? metadata : asset
        try deliver(first, records[first], to: target)
        ProfilePhotoStore.sweep(keeping: target.profiles, in: targetURL)
        let reopened = try ProfileDirectory(
            directory: targetURL,
            defaults: #require(UserDefaults(suiteName: "piru.tests.reopen.\(UUID())")),
            identities: ShareIdentityStore(storage: InMemoryShareIdentityStorage()),
        ) { _, _ in target.activeContainer }
        reopened.openActiveStore()
        let midway = try SyncProjection.metadataRecords(profileID: reopened.owner.id, directory: reopened)
        if assetFirst {
            #expect(target.owner.avatar.photo == nil)
        } else {
            #expect(midway[metadata] == records[metadata])
            #expect(midway[asset] == nil)
        }
        try deliver(second, records[second], to: reopened)
        try deliver(second, records[second], to: reopened)
        let restored = try #require(reopened.owner.avatar.photo)
        #expect(ProfilePhotoStore.data(named: restored, in: targetURL) == bytes)
        #expect(try SyncProjection.metadataRecords(profileID: reopened.owner.id, directory: reopened) == records)
        let other = try reopened.addProfile(name: "Other")
        #expect(try SyncProjection.fields(for: asset, in: reopened.activeContainer.mainContext, profileID: other.id, directory: reopened) == nil)
    }

    @Test
    func `photo replacements reuse content and late assets respect the latest selection`() throws {
        let (source, sourceURL) = try makeScratchProfileDirectory()
        let (target, targetURL) = try makeScratchProfileDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let first = try select(Data([1]), in: source)
        let second = try select(Data([2]), in: source)
        let firstKey = try #require(first.keys.first { $0 != metadata })
        let secondKey = try #require(second.keys.first { $0 != metadata })
        #expect(firstKey != secondKey)
        let again = try select(Data([1]), ext: "png", in: source)
        #expect(again[firstKey] == first[firstKey])
        #expect(again.count == 2)
        let onlyMetadata = try SyncProjection.metadataRecords(profileID: source.owner.id, directory: source, includeAsset: { _ in false })
        #expect(Set(onlyMetadata.keys) == [metadata])
        try deliver(metadata, first[metadata], to: target)
        try deliver(metadata, second[metadata], to: target)
        let pending = target.owner.avatar
        try deliver(firstKey, first[firstKey], to: target)
        #expect(target.owner.avatar == pending)
        try deliver(secondKey, second[secondKey], to: target)
        #expect(try ProfilePhotoStore.data(named: #require(target.owner.avatar.photo), in: targetURL) == Data([2]))
        try deliver(metadata, again[metadata], to: target)
        #expect(try ProfilePhotoStore.data(named: #require(target.owner.avatar.photo), in: targetURL) == Data([1]))
        let empty = try select(nil, in: source)
        try deliver(metadata, empty[metadata], to: target)
        try deliver(firstKey, first[firstKey], to: target)
        #expect(target.owner.avatar.photo == nil)
        #expect(throws: (any Error).self) {
            try deliver(firstKey, second[secondKey], to: target)
        }
        #expect(try SyncProjection.avatarAssetFields(firstKey, profileID: target.owner.id, directory: target) == first[firstKey])
    }

    @Test
    func `one megabyte photos seal independently of the metadata history`() throws {
        let (directory, folder) = try makeScratchProfileDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = UUID().uuidString.lowercased()
        let grant = UUID().uuidString.lowercased()
        let keys = SyncProfileKeys.generate()
        let sign = SyncWire.newSignPrivate()
        var history: Data?
        var before: SyncFields?
        var ids = Set<String>()
        for _ in 0 ..< 3 {
            var bytes = Data(count: PiruProfilesSection.maxPhotoBytes)
            try #require(bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) } == errSecSuccess)
            let records = try select(bytes, in: directory)
            let key = try #require(records.keys.first { $0 != metadata })
            let fields = try #require(records[metadata])
            history = try SyncDocument.localEdit(baseDoc: history, key: metadata, before: before, after: fields)
            before = fields
            let metaDoc = try #require(history)
            #expect(metaDoc.count < 4096)
            let assetDoc = try SyncDocument.localEdit(baseDoc: nil, key: key, before: nil, after: records[key])
            func seal(_ doc: Data) throws -> SyncEnvelope {
                try SyncWire.seal(
                    doc,
                    profileID: profile,
                    opID: UUID().uuidString.lowercased(),
                    grantID: grant,
                    epoch: 1,
                    keys: keys,
                    signPrivate: sign,
                )
            }
            let imageEnvelope = try seal(assetDoc)
            let metaEnvelope = try seal(metaDoc)
            #expect(imageEnvelope.docID != metaEnvelope.docID)
            #expect(ids.insert(imageEnvelope.docID).inserted)
            #expect(try SyncWire.decodeBase64URL(imageEnvelope.ciphertext).count <= 2 * 1024 * 1024)
        }
        #expect(throws: (any Error).self) {
            try select(Data(count: PiruProfilesSection.maxPhotoBytes + 1), in: directory)
        }
    }
}
