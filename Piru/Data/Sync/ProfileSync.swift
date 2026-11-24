import Foundation
import Network
import Observation
import SwiftData
import WidgetKit

@MainActor @Observable
final class ProfileSync {
    static let shared = ProfileSync()

    @ObservationIgnored private let account: SyncAccount

    init(account: SyncAccount = .shared) {
        self.account = account
    }

    private(set) var pending = 0
    private(set) var lastSync: Date?
    private(set) var working = false
    private(set) var issue: String?
    private(set) var history: [String] = []
    private var displayed: UUID?
    private var running = Set<UUID>()
    @ObservationIgnored private var failures = 0

    struct Status {
        let pending: Int
        let lastSync: Date?
        let working: Bool
        let issue: String?
        let history: [String]
    }

    func status(for profileID: UUID) -> Status? {
        guard displayed == profileID else { return nil }
        return Status(pending: pending, lastSync: lastSync, working: working, issue: issue, history: history)
    }

    func isSyncing(_ profileID: UUID) -> Bool {
        running.contains(profileID)
    }

    private func select(_ id: UUID) {
        guard displayed != id else { return }
        displayed = id
        pending = 0
        lastSync = nil
        issue = nil
        history = []
        working = running.contains(id)
        failures = 0
    }

    /// A SwiftUI task owns the entire foreground lifetime, including the save
    /// observer and network monitor. Buffer one trigger while a pass is busy.
    func monitor(profileID: UUID, container: ModelContainer) async {
        select(profileID)
        guard account.isLinked(localProfileID: profileID) else { return }
        let (stream, trigger) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let path = NWPathMonitor()
        path.pathUpdateHandler = { status in
            if status.status == .satisfied { trigger.yield(()) }
        }
        path.start(queue: DispatchQueue(label: "glass.kagerou.piru.sync.reachability"))
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { note in
            guard let saved = note.object as? ModelContext, saved.container === container,
                  saved.author != ProfileSyncJournal.author else { return }
            trigger.yield(())
        }
        let timer = Task {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(30 * (1 << min(failures, 4))))
                trigger.yield(())
            }
        }
        defer {
            timer.cancel()
            path.cancel()
            NotificationCenter.default.removeObserver(observer)
            trigger.finish()
        }
        trigger.yield(())
        for await _ in stream {
            do { try await Task.sleep(for: .milliseconds(450)) } catch { break }
            await sync(profileID: profileID, container: container)
        }
    }

    func sync(profileID: UUID, container: ModelContainer) async {
        let directory = ProfileDirectory.shared
        guard directory.profiles.contains(where: { $0.id == profileID }),
              directory.container(for: profileID, writable: true) === container,
              container.configurations.allSatisfy({ !$0.isStoredInMemoryOnly && $0.allowsSave }),
              account.isLinked(localProfileID: profileID) else { return }
        select(profileID)
        guard running.insert(profileID).inserted else { return }
        working = true
        defer {
            running.remove(profileID)
            if displayed == profileID { working = false }
        }
        do {
            guard let connection = try account.boundConnection(for: profileID) else { throw SyncAccount.Issue.missing }
            try await ProfileScope.$pinned.withValue(profileID) {
                try await replicate(connection, container: container)
            }
            if displayed == profileID { issue = nil; failures = 0 }
        } catch is CancellationError {
            return
        } catch {
            if displayed == profileID { issue = error.localizedDescription; failures = min(failures + 1, 4) }
        }
    }

    private func replicate(_ c: SyncAccount.Connection, container: ModelContainer) async throws {
        var revision = account.revision
        func checkBinding() throws {
            try Task.checkCancellation()
            if revision != account.revision {
                try account.ensureCurrent(c)
                revision = account.revision
            }
        }
        func journal() throws -> ProfileSyncJournal {
            try checkBinding()
            guard ProfileDirectory.shared.profiles.contains(where: { $0.id == c.localProfileID }),
                  ProfileDirectory.shared.container(for: c.localProfileID, writable: true) === container else { throw CancellationError() }
            return try ProfileSyncJournal(cloudID: c.profileID, profileID: c.localProfileID, container: container, checkBinding: checkBinding)
        }
        func publish(_ j: ProfileSyncJournal) throws {
            guard displayed == c.localProfileID else { return }
            pending = try j.context.fetchCount(j.outbox)
            lastSync = j.state.lastSync
            history = j.state.events
        }
        let first = try journal()
        func captureHistory() async throws {
            while try await journal().capture() {
                await Task.yield()
            }
        }
        let needsBootstrap = !first.state.bootstrapped
        if !needsBootstrap { try await captureHistory() }
        try publish(first)
        let startCursor = first.state.cursor
        var cursor = startCursor
        var epochs = [Int: SyncAccount.KeySet]()
        var changedKinds = Set<String>()
        defer {
            if !changedKinds.isEmpty {
                DoseLogService.shared.changed(in: c.localProfileID)
                if ProfileDirectory.shared.activeProfileID == c.localProfileID {
                    if changedKinds.contains("customSubstance") { CustomSubstanceStore.bindStore(container) }
                    if changedKinds.contains("customUnit") { CustomUnitStore.bindStore(container) }
                    if changedKinds.contains("userProfile") { UserProfileStore.bindStore(container) }
                    if changedKinds.contains("notificationPreferences") { NotificationPreferencesStore.bindStore(container) }
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
        }
        while true {
            let page = try await account.fetchChanges(for: c, after: cursor)
            guard page.cursor == (page.changes.last?.seq ?? cursor), !page.hasMore || page.cursor > cursor
            else { throw SyncTransport.Failure.malformed }
            for change in page.changes {
                let envelope = change.envelope
                guard cursor < Int.max, change.seq == cursor + 1 else { throw SyncTransport.Failure.malformed }
                if epochs[envelope.epoch]?.grants.contains(where: { $0.id == envelope.grantID }) != true {
                    epochs[envelope.epoch] = try await account.refreshedKeys(for: c, epoch: envelope.epoch)
                }
                guard let material = epochs[envelope.epoch],
                      let signer = material.grants.first(where: { $0.id == envelope.grantID })
                else { throw SyncWireError.invalidSignature }
                let remote = try SyncWire.open(envelope, profileID: c.profileID, grant: signer, keys: material.keys)
                let j = try journal()
                if let kind = try j.receive(remote, sequence: change.seq) {
                    changedKinds.insert(kind)
                }
                cursor = change.seq
            }
            if !page.hasMore { break }
        }
        let derived = try journal()
        if derived.state.inventoryDirty {
            InventoryService.recomputeAll(in: derived.context, notify: false)
            derived.state.inventoryDirty = false
            try derived.context.save()
        }
        if needsBootstrap || cursor != startCursor { try await captureHistory() }
        let uploads = try journal()
        try publish(uploads)
        let pendingAtStart = try uploads.context.fetchCount(uploads.outbox) > 0
        if pendingAtStart {
            let latest = try await account.refreshedKeys(for: c)
            while true {
                let j = try journal()
                let cloud = c.profileID
                var next = FetchDescriptor<ProfileSyncDocument>(predicate: #Predicate {
                    $0.cloudID == cloud && $0.pending && !$0.exceedsRelayLimit
                })
                next.fetchLimit = 1
                guard let row = try j.context.fetch(next).first else { break }
                guard row.document.count <= 2 * 1024 * 1024 - 16 else {
                    row.exceedsRelayLimit = true
                    try j.context.save()
                    continue
                }
                let key = SyncRecordKey(kind: row.kind, recordID: row.recordID)
                let envelope = try j.sealPending(row, for: c, material: latest)
                let receipt = try await account.postChange(envelope, for: c)
                guard receipt.seq > 0 else { throw SyncTransport.Failure.malformed }
                let ack = try journal()
                if let item = try ack.row(key), item.operationID == envelope.opID {
                    item.pending = false
                    item.envelope = nil
                    try ack.context.save()
                }
                if displayed == c.localProfileID { pending = max(0, pending - 1) }
            }
        }
        let end = try journal()
        let finished = Date.now
        if end.state.lastSync == nil || cursor != startCursor || pendingAtStart {
            end.state.lastSync = finished
            try end.context.save()
        }
        try publish(end)
        if try end.context.fetchCount(end.outbox) > 0 {
            throw SyncTransport.Failure.oversized
        }
        if displayed == c.localProfileID { lastSync = finished }
    }
}
