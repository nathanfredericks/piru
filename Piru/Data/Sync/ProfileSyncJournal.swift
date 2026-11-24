import Foundation
import SwiftData

/// The caller gives each transaction a fresh context. Capturing a local change
/// and advancing its history token are committed by the same save.
@MainActor
struct ProfileSyncJournal {
    nonisolated static let author = "piru.encrypted-profile-sync"
    let cloudID: String
    let profileID: UUID
    let directory: ProfileDirectory
    let context: ModelContext
    let state: ProfileSyncState
    private let checkBinding: @MainActor () throws -> Void

    init(cloudID: String, profileID: UUID, container: ModelContainer, directory: ProfileDirectory = .shared, checkBinding: @escaping @MainActor () throws -> Void = {}) throws {
        self.checkBinding = checkBinding
        self.directory = directory
        self.cloudID = cloudID
        self.profileID = profileID
        context = ModelContext(container)
        context.autosaveEnabled = false
        context.author = Self.author
        let descriptor = FetchDescriptor<ProfileSyncState>(predicate: #Predicate { $0.cloudID == cloudID })
        if let saved = try context.fetch(descriptor).first {
            state = saved
        } else {
            state = ProfileSyncState(cloudID: cloudID)
            context.insert(state)
        }
    }

    func row(_ key: SyncRecordKey) throws -> ProfileSyncDocument? {
        let cloud = cloudID
        let kind = key.kind
        let id = key.recordID
        var descriptor = FetchDescriptor<ProfileSyncDocument>(predicate: #Predicate {
            $0.cloudID == cloud && $0.kind == kind && $0.recordID == id
        })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    var outbox: FetchDescriptor<ProfileSyncDocument> {
        let cloud = cloudID
        return FetchDescriptor(predicate: #Predicate { $0.cloudID == cloud && $0.pending })
    }

    private func record(_ event: ProfileSyncEvent) {
        state.events = Array(([event.title.key] + state.events).prefix(40))
    }

    @discardableResult
    func capture() async throws -> Bool {
        let marker = Self.author
        var history = HistoryDescriptor<DefaultHistoryTransaction>(predicate: #Predicate {
            $0.author == nil || $0.author != marker
        })
        if let data = state.historyToken {
            let previous = try JSONDecoder().decode(DefaultHistoryToken.self, from: data)
            history.predicate = #Predicate { $0.token > previous && ($0.author == nil || $0.author != marker) }
        }
        if !state.bootstrapped {
            history.sortBy = [SortDescriptor(\.transactionIdentifier, order: .reverse)]
        }
        history.fetchLimit = state.bootstrapped ? 128 : 1
        let transactions: [DefaultHistoryTransaction]
        do {
            transactions = try context.fetchHistory(history)
        } catch SwiftDataError.historyTokenExpired {
            guard state.historyToken != nil else { throw SwiftDataError.historyTokenExpired }
            state.bootstrapped = false
            state.historyToken = nil
            try context.save()
            return try await capture()
        }
        if !state.bootstrapped {
            try await reconcile()
        } else {
            var keys = Set<SyncRecordKey>()
            for transaction in transactions {
                for change in transaction.changes {
                    if let key = try SyncProjection.recordKey(for: change, in: context, profileID: profileID) {
                        keys.insert(key)
                    }
                }
            }
            for key in keys {
                try capture(key, fields: SyncProjection.fields(for: key, in: context, profileID: profileID))
            }
            let metadata = try SyncProjection.metadataRecords(
                profileID: profileID,
                directory: directory,
                includeAsset: { try row($0) == nil },
            )
            for (key, fields) in metadata {
                try capture(key, fields: fields)
            }
        }
        if let token = transactions.last?.token {
            state.historyToken = try JSONEncoder().encode(token)
        }
        if context.hasChanges { try context.save() }
        return transactions.count == 128
    }

    private func reconcile() async throws {
        let scan = UUID()
        var count = 0
        func visit(_ key: SyncRecordKey, _ fields: SyncFields) throws {
            try capture(key, fields: fields, scan: scan)
            count += 1
            if count.isMultiple(of: 128) {
                try checkBinding()
                try Task.checkCancellation()
                try context.save()
            }
        }
        for (key, fields) in try SyncProjection.metadataRecords(profileID: profileID, directory: directory) {
            try visit(key, fields)
        }
        for table in SyncProjection.tables {
            try await table.scan(in: context, visit)
        }
        try checkBinding()
        if context.hasChanges { try context.save() }
        let cloud = cloudID
        let descriptor = FetchDescriptor<ProfileSyncDocument>(predicate: #Predicate {
            $0.cloudID == cloud && ($0.scanID == nil || $0.scanID != scan)
        })
        try context.enumerate(descriptor, batchSize: 128, allowEscapingMutations: true) { item in
            guard item.scanID != scan, item.fields != nil, item.kind != SyncProjection.avatarAssetKind else { return }
            try capture(SyncRecordKey(kind: item.kind, recordID: item.recordID), fields: nil)
        }
        state.bootstrapped = true
    }

    static func encode(_ fields: SyncFields?) throws -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try fields.map(encoder.encode)
    }

    func capture(_ key: SyncRecordKey, fields: SyncFields?, scan: UUID? = nil) throws {
        let previous = try row(key)
        if let scan { previous?.scanID = scan }
        let encoded = try Self.encode(fields)
        guard encoded != previous?.fields else { return }
        if let previous, previous.fields == nil, try SyncDocument.fields(previous.document) == nil {
            if let fields, let successor = try SyncProjection.renewIdentity(for: key, in: context) {
                try capture(successor, fields: fields, scan: scan)
            } else {
                try SyncProjection.apply(key, fields: nil, in: context, profileID: profileID, directory: directory)
            }
            return
        }
        let before = try previous?.fields.map { try JSONDecoder().decode(SyncFields.self, from: $0) }
        let updated = try SyncDocument.localEdit(baseDoc: previous?.document, key: key, before: before, after: fields)
        if let previous {
            previous.document = updated
            previous.fields = encoded
            previous.pending = true
            previous.exceedsRelayLimit = false
            previous.operationID = UUID().uuidString.lowercased()
            previous.envelope = nil
        } else {
            let row = ProfileSyncDocument(
                cloudID: cloudID,
                kind: key.kind,
                recordID: key.recordID,
                document: updated,
                fields: encoded,
                pending: true,
            )
            row.scanID = scan
            context.insert(row)
        }
    }
}

extension ProfileSyncJournal {
    func sealPending(_ row: ProfileSyncDocument, for connection: SyncAccount.Connection, material: SyncAccount.KeySet) throws -> SyncEnvelope {
        if let data = row.envelope {
            let saved = try JSONDecoder().decode(SyncEnvelope.self, from: data)
            if saved.epoch == material.epoch, saved.grantID == connection.grantID { return saved }
            row.operationID = UUID().uuidString.lowercased()
        }
        let sealed = try SyncWire.seal(
            row.document,
            profileID: cloudID,
            opID: row.operationID,
            grantID: connection.grantID,
            epoch: material.epoch,
            keys: material.keys,
            signPrivate: connection.signPrivate,
        )
        row.envelope = try JSONEncoder().encode(sealed)
        try context.save()
        return sealed
    }

    private struct MergeReference: Codable {
        let cloudID: String
        let key: SyncRecordKey
        let heads: Data
    }

    private static let mergePrefix = "merge-v1."

    static func isMergeReference(_ stored: String) -> Bool {
        stored.hasPrefix(mergePrefix)
    }

    static func mergeDetail(for stored: String, in context: ModelContext) throws -> SyncMergeDetail? {
        guard isMergeReference(stored) else { return nil }
        let bytes = try SyncWire.decodeBase64URL(String(stored.dropFirst(mergePrefix.count)))
        let reference = try JSONDecoder().decode(MergeReference.self, from: bytes)
        let cloud = reference.cloudID
        let kind = reference.key.kind
        let id = reference.key.recordID
        var query = FetchDescriptor<ProfileSyncDocument>(predicate: #Predicate {
            $0.cloudID == cloud && $0.kind == kind && $0.recordID == id
        })
        query.fetchLimit = 1
        guard let row = try context.fetch(query).first else { return nil }
        return try SyncDocument.mergeDetail(row.document, heads: reference.heads)
    }

    private func recordMerge(_ key: SyncRecordKey, heads: Data) throws {
        let ref = MergeReference(cloudID: cloudID, key: key, heads: heads)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let stored = try Self.mergePrefix + SyncWire.base64URL(encoder.encode(ref))
        if !state.events.contains(stored) { state.events = Array(([stored] + state.events).prefix(40)) }
    }

    /// Natural-key rows may still lack a syncID when an import or a widget save races a pull.
    /// Advance this probe independently of capture's token: capture still owes those writes an upload.
    private func prepareFirstReceipt(for key: SyncRecordKey) throws {
        guard let table = SyncProjection.tablesByKind[key.kind], !table.singleton else { return }
        let marker = Self.author
        var history = HistoryDescriptor<DefaultHistoryTransaction>(predicate: #Predicate {
            $0.author == nil || $0.author != marker
        })
        history.sortBy = [SortDescriptor(\.transactionIdentifier, order: .reverse)]
        history.fetchLimit = 1
        let latest = try context.fetchHistory(history).first
        let identifier = latest?.transactionIdentifier ?? 0
        guard identifier != state.identityBackfillTransaction else { return }
        let captured = try state.historyToken.map { try JSONDecoder().decode(DefaultHistoryToken.self, from: $0) }
        if captured == nil || captured != latest?.token {
            try SyncProjection.backfillStableIDs(in: context)
        }
        state.identityBackfillTransaction = identifier
    }

    private func localSeed(_ key: SyncRecordKey) throws -> SyncFields? {
        // A download profile's provisional name, color and avatar come from the profile creation UI.
        if !state.bootstrapped, key.kind == SyncProjection.metadataKind { return nil }
        guard let fields = try SyncProjection.fields(for: key, in: context, profileID: profileID, directory: directory) else {
            return nil
        }
        guard !state.bootstrapped else { return fields }
        switch key.kind {
        case SyncProjection.notificationPreferences.kind:
            return try authoredFields(fields, in: SyncProjection.notificationPreferences)
        case SyncProjection.userProfileRecord.kind:
            return try authoredFields(fields, in: SyncProjection.userProfileRecord)
        default:
            return fields
        }
    }

    private func authoredFields(_ fields: SyncFields, in table: SyncTable<some Any>) throws -> SyncFields? {
        let defaults = table.create(SyncProjection.singletonID)
        var authored = fields
        for column in table.columns where try authored[column.name] == column.read(defaults) {
            authored.removeValue(forKey: column.name)
        }
        return authored.isEmpty ? nil : authored
    }

    func receive(_ snapshot: Data, sequence: Int) throws -> String? {
        let key = try SyncDocument.key(snapshot)
        var existing = try row(key)
        if key.kind == SyncProjection.avatarAssetKind, let existing {
            let incomingFields = try SyncDocument.fields(snapshot)
            guard let incomingFields, try SyncDocument.fields(existing.document) == incomingFields else {
                throw SyncProjectionError.invalidField("bytes")
            }
            try SyncProjection.apply(key, fields: incomingFields, in: context, profileID: profileID, directory: directory)
            state.cursor = sequence
            try context.save()
            return nil
        }
        if existing != nil {
            let local = try SyncProjection.fields(for: key, in: context, profileID: profileID, directory: directory)
            try capture(key, fields: local)
        } else {
            try prepareFirstReceipt(for: key)
            if let seed = try localSeed(key) {
                try capture(key, fields: seed)
                existing = try row(key)
            }
        }
        let receipt = try SyncDocument.receive(snapshot, previous: existing?.document)
        let merged = receipt.document
        let result = receipt.fields
        let changed = receipt.projectionChanged
        let mergePoints = receipt.mergePoints
        if changed {
            try SyncProjection.apply(key, fields: result, in: context, profileID: profileID, directory: directory)
            if mergePoints.isEmpty { record(result == nil ? .deletion : .change) }
        }
        for heads in mergePoints { try recordMerge(key, heads: heads) }
        let localFields = try Self.encode(SyncProjection.fields(for: key, in: context, profileID: profileID, directory: directory))
        if let existing {
            existing.document = merged
            existing.fields = localFields
        } else {
            context.insert(ProfileSyncDocument(
                cloudID: cloudID,
                kind: key.kind,
                recordID: key.recordID,
                document: merged,
                fields: localFields,
                pending: false,
            ))
        }
        if changed, key.kind == "dose" || key.kind == "inventoryItem" { state.inventoryDirty = true }
        state.cursor = sequence
        try context.save()
        return changed ? key.kind : nil
    }
}

/// History stores a catalog key so an event follows the language selected when the journal is opened.
enum ProfileSyncEvent: CaseIterable {
    case deletion
    case merge
    case change

    var title: LocalizedStringResource {
        switch self {
        case .deletion: "Deletion synced"
        case .merge: "Edits merged automatically"
        case .change: "Change received"
        }
    }

    static func title(for stored: String) -> LocalizedStringResource? {
        if ProfileSyncJournal.isMergeReference(stored) { return merge.title }
        return titlesByLabel[stored]
    }

    /// Also recognize event labels already saved in any of the app's languages.
    private static let titlesByLabel: [String: LocalizedStringResource] = {
        let titles = allCases.map(\.title)
        var labels = Dictionary(uniqueKeysWithValues: titles.map { ($0.key, $0) })
        for language in Bundle.main.localizations {
            guard let path = Bundle.main.url(forResource: language, withExtension: "lproj"),
                  let bundle = Bundle(url: path) else { continue }
            for title in titles {
                labels[bundle.localizedString(forKey: title.key, value: nil, table: nil)] = title
            }
        }
        return labels
    }()
}
