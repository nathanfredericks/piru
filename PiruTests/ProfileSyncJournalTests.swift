import Foundation
import SwiftData
import Testing
@testable import Piru

@MainActor
@Suite("Profile sync journal history")
struct ProfileSyncJournalTests {
    @Test
    func `incremental capture and lost acknowledgment`() async throws {
        try await measureJournal(count: 8)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PIRU_SYNC_BENCHMARK"] == "1"))
    func `large journal`() async throws {
        try await measureJournal(count: 3000)
    }

    @Test
    func `first receipt seeds a committed local favorite before its ID is backfilled`() throws {
        let (directory, folder) = try makeScratchProfileDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = directory.activeContainer.mainContext
        let favorite = FavoriteSubstance(substance: "Synthetic", sortOrder: 42)
        local.insert(favorite)
        try local.save()
        let id = try SyncProjection.stableID("favorite", parts: ["Synthetic"])
        let key = SyncRecordKey(kind: "favorite", id: id)
        let remote = try SyncDocument.localEdit(
            baseDoc: nil,
            key: key,
            before: nil,
            after: ["substance": #""Synthetic""#, "futureField": "true"],
        )
        let journal = try ProfileSyncJournal(
            cloudID: UUID().uuidString.lowercased(),
            profileID: directory.owner.id,
            container: directory.activeContainer,
            directory: directory,
        )
        _ = try journal.receive(remote, sequence: 1)
        let shadow = try #require(try journal.row(key))
        let projected = try SyncDocument.fields(shadow.document)
        #expect(projected?["sortOrder"] == "42")
        #expect(projected?["futureField"] == "true")
        #expect(shadow.pending)
    }

    @Test
    func `favoriting the same substance again sends a successor`() throws {
        let (directory, folder) = try makeScratchProfileDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try ProfileSyncJournal(
            cloudID: UUID().uuidString.lowercased(),
            profileID: directory.owner.id,
            container: directory.activeContainer,
            directory: directory,
        )
        let id = try SyncProjection.stableID("favorite", parts: ["Synthetic"])
        let key = SyncRecordKey(kind: "favorite", id: id)
        let deleted = try SyncDocument.localEdit(baseDoc: nil, key: key, before: nil, after: nil)
        _ = try journal.receive(deleted, sequence: 1)

        let added = FavoriteSubstance(substance: "Synthetic")
        journal.context.insert(added)
        try journal.context.save()
        try SyncProjection.backfillStableIDs(in: journal.context)
        #expect(added.syncID == id)
        let fields = try SyncProjection.fields(for: key, in: journal.context, profileID: directory.owner.id)
        try journal.capture(key, fields: fields)
        try journal.context.save()
        let renewed = try #require(added.syncID)
        #expect(renewed != id)
        let previous = try #require(try journal.row(key))
        #expect(try SyncDocument.fields(previous.document) == nil)
        let successor = try #require(try journal.row(SyncRecordKey(kind: "favorite", id: renewed)))
        #expect(successor.pending)
        #expect(try SyncDocument.fields(successor.document) == fields)
    }

    @Test
    func `losing incoming edit remains readable after replay and later edits`() throws {
        let (directory, folder) = try makeScratchProfileDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = directory.activeContainer.mainContext
        let dose = DoseEntry(substance: "Synthetic", amount: 1)
        context.insert(dose)
        try context.save()
        let key = SyncRecordKey(kind: "dose", id: dose.id)
        let original = try #require(try SyncProjection.fields(for: key, in: context, profileID: directory.owner.id))
        let base = try SyncDocument.localEdit(baseDoc: nil, key: key, before: nil, after: original)
        func branch(_ note: String) throws -> Data {
            var fields = original
            fields["notes"] = try SyncJSON.encode(note)
            return try SyncDocument.localEdit(baseDoc: base, key: key, before: original, after: fields)
        }
        let left = try branch("first note")
        let right = try branch("second note")
        let combined = try SyncDocument.merge(left, right)
        let winningFields = try #require(try SyncDocument.fields(combined))
        let leftWon = try SyncDocument.fields(left) == winningFields
        let winner = leftWon ? left : right
        let loser = leftWon ? right : left
        let journal = try ProfileSyncJournal(
            cloudID: UUID().uuidString.lowercased(),
            profileID: directory.owner.id,
            container: directory.activeContainer,
            directory: directory,
        )
        try SyncProjection.apply(key, fields: winningFields, in: journal.context, profileID: journal.profileID)
        let shadow = try ProfileSyncDocument(
            cloudID: journal.cloudID,
            kind: key.kind,
            recordID: key.recordID,
            document: winner,
            fields: ProfileSyncJournal.encode(winningFields),
            pending: false,
        )
        journal.context.insert(shadow)
        try journal.context.save()

        #expect(try journal.receive(loser, sequence: 1) == nil)
        let reference = try #require(journal.state.events.first)
        #expect(ProfileSyncJournal.isMergeReference(reference))
        _ = try journal.receive(loser, sequence: 2)
        #expect(journal.state.events == [reference])
        var later = winningFields
        later["notes"] = #""later note""#
        let updated = try SyncDocument.localEdit(baseDoc: combined, key: key, before: winningFields, after: later)
        _ = try journal.receive(updated, sequence: 3)
        let detail = try #require(try ProfileSyncJournal.mergeDetail(for: reference, in: ModelContext(directory.activeContainer)))
        #expect(detail.result == winningFields)
        #expect(detail.conflicts["notes"] == [#""first note""#, #""second note""#])
        #expect(Set(detail.versions.compactMap { $0?["notes"] }) == Set([#""first note""#, #""second note""#]))
        #expect(try SyncDocument.fields(shadow.document) == later)
    }

    private func measureJournal(count: Int) async throws {
        let (directory, folder) = try makeScratchProfileDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let container = directory.activeContainer
        let profile = directory.owner.id
        let token = SyncAccount.makeToken(url: "http://127.0.0.1", profileID: UUID().uuidString.lowercased())
        let connection = SyncAccount.Connection(localProfileID: profile, accountID: UUID().uuidString.lowercased(), token: token)
        let epoch = SyncAccount.KeySet(epoch: 1, keys: .generate(), grants: [])
        func journal() throws -> ProfileSyncJournal {
            try ProfileSyncJournal(cloudID: token.profileID, profileID: profile, container: container, directory: directory)
        }
        let seed = ModelContext(container)
        let entry = DoseEntry(substance: "Synthetic", amount: 2)
        seed.insert(entry)
        for i in 1 ..< count {
            seed.insert(DoseEntry(substance: "Synthetic", amount: Double(i)))
        }
        try seed.save()

        let clock = ContinuousClock()
        let initial = try journal()
        let bootstrapStart = clock.now
        _ = try await initial.capture()
        let bootstrap = bootstrapStart.duration(to: clock.now)
        let rows = try initial.context.fetch(initial.outbox)
        #expect(rows.filter { $0.kind == "dose" }.count == count)
        let snapshotBytes = rows.reduce(0) { $0 + $1.document.count }
        for row in rows { row.pending = false }
        try initial.context.save()
        let idle = try journal()
        let idleDurationStart = clock.now
        _ = try await idle.capture()
        let idleDuration = idleDurationStart.duration(to: clock.now)
        #expect(try idle.context.fetchCount(idle.outbox) == 0)
        entry.notes = "Synthetic note"
        try seed.save()
        let changed = try journal()
        let editDurationStart = clock.now
        _ = try await changed.capture()
        let editDuration = editDurationStart.duration(to: clock.now)
        let queue = try changed.context.fetch(changed.outbox)
        try #require(queue.count == 1)
        let envelope = try changed.sealPending(queue[0], for: connection, material: epoch)
        let resumed = try journal()
        let persisted = try #require(try resumed.context.fetch(resumed.outbox).first)
        #expect(try resumed.sealPending(persisted, for: connection, material: epoch) == envelope)
        let bytes = try JSONEncoder().encode(envelope).count
        print("PiruSync benchmark rows=\(count) bootstrap=\(bootstrap) idle=\(idleDuration) edit=\(editDuration) bootstrapDocBytes=\(snapshotBytes) singleEditEnvelopeBytes=\(bytes)")
        seed.delete(entry)
        try seed.save()
        let deleted = try journal()
        try await deleted.capture()
        let pending = try #require(try deleted.context.fetch(deleted.outbox).first)
        #expect(pending.fields == nil)
        #expect(try SyncDocument.fields(pending.document) == nil)
    }
}
