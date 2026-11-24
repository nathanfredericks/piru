import Foundation
import SwiftData
import Testing
@testable import Piru

@Suite("Journal Sync local link eligibility")
@MainActor
struct SyncAccountLinkingTests {
    private struct EmptyStorage: SyncAccountStorage {
        func read<T: Decodable>(_: T.Type, at _: String) throws -> T? { nil }
        func write(_: some Encodable, at _: String) throws { throw FixtureError.unexpectedWrite }
        func remove(_: String) throws { throw FixtureError.unexpectedWrite }
    }

    private enum FixtureError: Error { case unexpectedWrite }

    private func account(_ directory: ProfileDirectory) throws -> SyncAccount {
        let relay = try SyncTransport(url: #require(URL(string: "https://piru.invalid")))
        return try SyncAccount(
            relay: .success(relay),
            defaults: #require(UserDefaults(suiteName: "piru.tests.link.\(UUID())")),
            linkDirectory: directory, device: EmptyStorage(), codes: EmptyStorage(), cloudCodes: EmptyStorage(),
        )
    }

    @Test
    func `Seeded rows and sync shadows allow linking but any authored row blocks enrollment`() async throws {
        let (directory, _) = try makeScratchProfileDirectory()
        let account = try account(directory)
        let profile = try directory.addProfile(name: "Local")
        let container = try #require(directory.activate(profile.id))
        let main = container.mainContext
        main.insert(ToleranceState(target: "fixture"))
        main.insert(NotificationPreferences())
        main.insert(ProfileSyncState(cloudID: "cloud"))
        main.insert(ProfileSyncDocument(cloudID: "cloud", kind: "fixture", recordID: "record", document: Data(), fields: nil, pending: false))
        try main.save()
        #expect(try account.isEmptyForLinking(profile.id))

        main.insert(DailyDoseItem(substance: "Fixture", amount: 12))
        #expect(try !account.isEmptyForLinking(profile.id))
        main.rollback()
        #expect(try account.isEmptyForLinking(profile.id))
        let other = ModelContext(container)
        other.insert(DoseEntry(substance: "Fixture", amount: 12))
        try other.save()
        #expect(try !account.isEmptyForLinking(profile.id))
        do {
            try await account.link(localProfileID: profile.id, profileID: UUID().uuidString.lowercased(), recoveryCode: nil, requireActive: true)
            Issue.record("Enrollment accepted a populated store")
        } catch SyncAccount.Issue.needsEmptyProfile {}
        #expect(!account.isLinked(localProfileID: profile.id))
    }

    @Test
    func `Existing targets must retain identity and selection`() throws {
        let (directory, _) = try makeScratchProfileDirectory()
        let account = try account(directory)
        let profile = try directory.addProfile(name: "Existing")
        _ = try #require(directory.activate(profile.id))
        let target = try #require(try account.linkTarget(profile.id, requireActive: true))
        _ = try #require(directory.activate(directory.owner.id))
        #expect(try account.linkTarget(profile.id, requireActive: true) == nil)
        try directory.deleteProfile(id: profile.id)
        #expect(try account.linkTarget(profile.id, requireActive: false) != target)
    }

    @Test
    func `A new UUID must have no registry entry or existing store files`() throws {
        let (directory, folder) = try makeScratchProfileDirectory()
        let account = try account(directory)
        let newID = UUID()
        #expect(try account.isEmptyForLinking(newID))
        #expect(try account.linkTarget(newID, requireActive: true) == nil)
        try Data().write(to: folder.appendingPathComponent(PiruProfile.storeFileName(for: newID) + "-wal"))
        #expect(try !account.isEmptyForLinking(newID))

        let person = try directory.savePerson(personID: UUID(), name: "Person", avatar: .monogram(for: "Person"), publicKey: Data(repeating: 1, count: 32))
        #expect(try !account.isEmptyForLinking(person.id))
        #expect(try !account.isEmptyForLinking(PiruProfile.legacyOwnerID))
    }

    @Test
    func `A damaged registered journal cannot qualify through the in-memory fallback`() throws {
        let (directory, _) = try makeScratchProfileDirectory()
        let account = try account(directory)
        let profile = try directory.addProfile(name: "Damaged")
        try Data("damaged".utf8).write(to: directory.storeURL(for: profile))
        do {
            _ = try account.isEmptyForLinking(profile.id)
            Issue.record("A damaged journal produced an emptiness verdict")
        } catch SyncAccount.Issue.storeUnavailable {}
        #expect(!account.isLinked(localProfileID: profile.id))
    }
}
