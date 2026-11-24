import Foundation
import SwiftData

/// Typed, explicit wire fields. Decode every incoming field before mutating the managed object.
@MainActor
struct SyncField<Row> {
    let name: String
    let read: (Row) throws -> String?
    let prepare: (String, ModelContext) throws -> (Row) -> Void
    var requiredOnInsert = true

    init(_ name: String, _ path: ReferenceWritableKeyPath<Row, some Codable>) {
        self.init(name, get: { $0[keyPath: path] }, set: { $0[keyPath: path] = $1 })
    }

    init<Value: Codable>(_ name: String, get: @escaping (Row) -> Value, set: @escaping (Row, Value) -> Void) {
        self.name = name
        read = { try SyncJSON.encode(get($0)) }
        prepare = { json, _ in
            let value = try SyncJSON.decode(Value.self, from: json)
            return { set($0, value) }
        }
    }

    init(
        _ name: String, required: Bool = true, read: @escaping (Row) throws -> String?,
        prepare: @escaping (String, ModelContext) throws -> (Row) -> Void,
    ) {
        self.name = name
        self.read = read
        self.prepare = prepare
        requiredOnInsert = required
    }
}

@MainActor
protocol SyncModelTable {
    var kind: String { get }
    var entity: String { get }
    var singleton: Bool { get }
    func forEachRecord(in context: ModelContext, _ visit: (SyncRecordKey, SyncFields) throws -> Void) throws
    func scan(in context: ModelContext, _ visit: (SyncRecordKey, SyncFields) throws -> Void) async throws
    func backfill(in context: ModelContext) throws
    func fields(id: UUID, in context: ModelContext) throws -> SyncFields?
    func liveKey(_ pid: PersistentIdentifier, in context: ModelContext) throws -> SyncRecordKey?
    func deletedKey(_ deletion: any HistoryDelete) -> SyncRecordKey?
    func renewIdentity(id: UUID, in context: ModelContext) throws -> SyncRecordKey?
    func apply(id: UUID, fields: SyncFields?, in context: ModelContext) throws
}

@MainActor
struct SyncTable<Row: PersistentModel>: SyncModelTable {
    let kind: String
    var entity: String { String(describing: Row.self) }
    var singleton: Bool { tombstonePath == nil }
    let tombstonePath: PartialKeyPath<Row>?
    let identify: (Row) -> UUID?
    let assign: (Row, UUID) -> Void
    let seed: ((Row) throws -> [String])?
    let predicate: (UUID) -> Predicate<Row>?
    let create: (UUID) -> Row
    let columns: [SyncField<Row>]
    var projectExtras: (@MainActor (Row) throws -> SyncFields)?
    var prepareExtras: (@MainActor (SyncFields) throws -> (Row) -> Void)?
    var naturalMatch: (@MainActor (SyncFields, ModelContext) throws -> Row?)?
    var afterWrite: (@MainActor (Row, ModelContext) throws -> Void)?
    var beforeDelete: (@MainActor (Row) -> Void)?
    var visible: (Row) -> Bool = { _ in true }

    private func find(_ id: UUID, in context: ModelContext) throws -> Row? {
        var request = FetchDescriptor<Row>(predicate: predicate(id))
        request.fetchLimit = 2
        let rows = try context.fetch(request).filter { !$0.isDeleted }
        guard rows.count <= 1 else { throw SyncProjectionError.duplicateIdentity(kind) }
        return rows.first
    }

    /// A collision between distinct rows with identical editable keys must retain both rows.
    /// SwiftData's local row identity only breaks ties; it never leaves this store.
    private func stableID(_ row: Row, in context: ModelContext) throws -> UUID {
        if let id = identify(row) { return id }
        guard let seed else { throw SyncProjectionError.duplicateIdentity(kind) }
        let parts = try seed(row)
        var id = try SyncProjection.stableID(kind, parts: parts)
        if let other = try find(id, in: context), other !== row {
            id = try SyncProjection.stableID(kind, parts: parts + [SyncJSON.encode(row.persistentModelID)])
            if let other = try find(id, in: context), other !== row { throw SyncProjectionError.duplicateIdentity(kind) }
        }
        assign(row, id)
        return id
    }

    func backfill(in context: ModelContext) throws {
        guard seed != nil else { return }
        // Enumerate a fixed membership: assigning an ID must not shrink a paged predicate.
        try context.enumerate(FetchDescriptor<Row>(), batchSize: 128, allowEscapingMutations: true) { row in
            if identify(row) == nil { _ = try stableID(row, in: context) }
        }
    }

    func forEachRecord(in context: ModelContext, _ visit: (SyncRecordKey, SyncFields) throws -> Void) throws {
        try context.enumerate(FetchDescriptor<Row>(), batchSize: 128, allowEscapingMutations: true) { row in
            guard !row.isDeleted, visible(row) else { return }
            let key = try SyncRecordKey(kind: kind, id: stableID(row, in: context))
            try visit(key, project(row))
        }
    }

    /// Keep the fixed fetch membership while allowing the foreground UI to run between batches.
    func scan(in context: ModelContext, _ visit: (SyncRecordKey, SyncFields) throws -> Void) async throws {
        var descriptor = FetchDescriptor<Row>()
        descriptor.includePendingChanges = false
        let batch = try context.fetch(descriptor, batchSize: 64)
        for (index, row) in batch.enumerated() {
            if index.isMultiple(of: 16) {
                await Task.yield()
                try Task.checkCancellation()
            }
            if !row.isDeleted, visible(row) {
                try visit(SyncRecordKey(kind: kind, id: stableID(row, in: context)), project(row))
            }
        }
    }

    private func project(_ row: Row) throws -> SyncFields {
        var fields = try projectExtras?(row) ?? [:]
        for column in columns {
            fields[column.name] = try column.read(row)
        }
        return fields
    }

    func fields(id: UUID, in context: ModelContext) throws -> SyncFields? {
        guard let row = try find(id, in: context), visible(row) else { return nil }
        return try project(row)
    }

    func renewIdentity(id: UUID, in context: ModelContext) throws -> SyncRecordKey? {
        guard seed != nil, let row = try find(id, in: context) else { return nil }
        let next = try SyncProjection.stableID(kind, parts: ["successor", id.uuidString.lowercased()])
        guard try find(next, in: context) == nil else { throw SyncProjectionError.duplicateIdentity(kind) }
        assign(row, next)
        return SyncRecordKey(kind: kind, id: next)
    }

    func liveKey(_ pid: PersistentIdentifier, in context: ModelContext) throws -> SyncRecordKey? {
        var request = FetchDescriptor<Row>(predicate: #Predicate { $0.persistentModelID == pid })
        request.fetchLimit = 1
        guard let row = try context.fetch(request).first, !row.isDeleted else { return nil }
        return try SyncRecordKey(kind: kind, id: stableID(row, in: context))
    }

    func deletedKey(_ deletion: any HistoryDelete) -> SyncRecordKey? {
        guard let change = deletion as? any HistoryDelete<Row> else { return nil }
        guard let path = tombstonePath else { return SyncRecordKey(kind: kind, id: SyncProjection.singletonID) }
        guard let id = change.tombstone[path] as? UUID else { return nil }
        return SyncRecordKey(kind: kind, id: id)
    }

    func apply(id: UUID, fields: SyncFields?, in context: ModelContext) throws {
        var existing = try find(id, in: context)
        guard let fields else {
            if let existing, visible(existing) {
                beforeDelete?(existing)
                context.delete(existing)
            }
            return
        }
        if let match = try naturalMatch?(fields, context), match !== existing {
            guard existing == nil, let seed else {
                throw SyncProjectionError.duplicateIdentity(kind)
            }
            if visible(match) {
                let canonical = try SyncProjection.stableID(kind, parts: seed(match))
                guard identify(match) == nil, canonical == id else { throw SyncProjectionError.duplicateIdentity(kind) }
            }
            existing = match
        }
        let setters = try columns.compactMap { column -> ((Row) -> Void)? in
            guard let json = fields[column.name] else {
                if existing == nil, column.requiredOnInsert { throw SyncProjectionError.missingField(column.name) }
                return nil
            }
            return try column.prepare(json, context)
        }
        let extra = try prepareExtras?(fields)
        let row = existing ?? create(id)
        if identify(row) != id { assign(row, id) }
        for set in setters { set(row) }
        extra?(row)
        if existing == nil { context.insert(row) }
        try afterWrite?(row, context)
    }
}
