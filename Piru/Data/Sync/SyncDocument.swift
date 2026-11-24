import Automerge
import Foundation

nonisolated struct SyncDocumentRevision: Equatable, Sendable {
    let changeID: String
    let parents: [String]
    let fields: SyncFields?
}

nonisolated enum SyncDocumentError: Error {
    case invalidRecord
    case invalidField(String)
    case differentRecord
}

nonisolated enum SyncDocument {
    private static let kind = "kind"
    private static let recordID = "recordID"
    private static let deleted = "_deleted"
    private static let reserved: Set<String> = [kind, recordID, deleted, "__proto__", "constructor", "prototype"]

    /// The built-in ROOT map is shared by all actors, including independent bootstraps.
    /// Every projection field (including the complete dose tuple) is one scalar register.
    static func localEdit(baseDoc: Data?, key: SyncRecordKey, before: SyncFields?, after: SyncFields?) throws -> Data {
        try validate(key)
        let doc: Document
        if let baseDoc {
            doc = try Document(baseDoc)
            guard try identity(doc) == key else { throw SyncDocumentError.differentRecord }
            if try isDeleted(doc) { return baseDoc }
        } else {
            doc = Document()
            try doc.put(obj: .ROOT, key: kind, value: .String(key.kind))
            try doc.put(obj: .ROOT, key: recordID, value: .String(key.recordID))
        }
        let original = baseDoc == nil ? [:] : before ?? [:]
        guard let after else {
            try doc.put(obj: .ROOT, key: deleted, value: .String("true"))
            return doc.save()
        }
        for name in Set(original.keys).union(after.keys).sorted() {
            guard !reserved.contains(name), !name.isEmpty else { throw SyncDocumentError.invalidField(name) }
            if let value = after[name] {
                if original[name] != value {
                    try validateJSON(value, field: name)
                    try doc.put(obj: .ROOT, key: name, value: .String(value))
                }
            } else {
                try doc.delete(obj: .ROOT, key: name)
            }
        }
        return doc.save()
    }

    static func merge(_ lhs: Data, _ rhs: Data) throws -> Data {
        let merged = try Document(rhs)
        _ = try merge(merged, with: Document(lhs))
        return merged.save()
    }

    private static func merge(_ doc: Document, with other: Document) throws -> SyncFields? {
        guard try identity(doc) == identity(other) else { throw SyncDocumentError.differentRecord }
        let hasTombstone = try isDeleted(doc) || isDeleted(other)
        try doc.merge(other: other)
        let result = try projection(doc)
        guard !hasTombstone || result == nil else { throw SyncDocumentError.invalidRecord }
        return result
    }

    struct Receipt {
        let document: Data
        let fields: SyncFields?
        let projectionChanged: Bool
        let mergePoints: [Data]
    }

    static func receive(_ incoming: Data, previous: Data?) throws -> Receipt {
        let doc = try Document(incoming)
        let receivedHeads = doc.heads()
        let prior = try previous.map { try Document($0) }
        let fields = try prior.map { try merge(doc, with: $0) } ?? projection(doc)
        let heads = doc.heads()
        let changed = try prior == nil || prior.flatMap { try projection($0) } != fields
        let points = try mergePoints(in: doc, previous: prior)
        return Receipt(
            document: heads == receivedHeads ? incoming : doc.save(),
            fields: fields,
            projectionChanged: changed,
            mergePoints: points,
        )
    }

    /// Concurrent branches have no synthetic merge commit. The set of heads identifies
    /// their exact combined state, even when the first envelope already contains a later edit.
    private static func mergePoints(in doc: Document, previous: Document?) throws -> [Data] {
        let final = doc.heads()
        if let previous, previous.heads() == final { return [] }
        var visited = Set<ChangeHash>()
        var recorded = Set<Data>()
        var ordered: [Data] = []
        func record(_ heads: Set<ChangeHash>) {
            let bytes = heads.raw()
            if recorded.insert(bytes).inserted { ordered.append(bytes) }
        }
        // Visit parents before children without recursing on the depth of a long offline history.
        var pending = final.map { ($0, false) }
        while let (hash, expanded) = pending.popLast() {
            if !expanded {
                guard visited.insert(hash).inserted, previous?.change(hash: hash) == nil else { continue }
            }
            guard let change = doc.change(hash: hash) else { throw SyncDocumentError.invalidRecord }
            if expanded {
                if change.deps.count > 1, change.deps.contains(where: { previous?.change(hash: $0) == nil }) {
                    record(Set(change.deps))
                }
            } else {
                if change.deps.count > 1 { pending.append((hash, true)) }
                pending.append(contentsOf: change.deps.map { ($0, false) })
            }
        }
        if final.count > 1 { record(final) }
        return ordered
    }

    static func mergeDetail(_ snapshot: Data, heads encoded: Data) throws -> SyncMergeDetail {
        let doc = try Document(snapshot)
        guard let heads = encoded.heads(), heads.count > 1, heads.allSatisfy({ doc.change(hash: $0) != nil }) else {
            throw SyncDocumentError.invalidRecord
        }
        let versions = try heads.sorted { $0.debugDescription < $1.debugDescription }.map { try projection(doc, at: [$0]) }
        var conflicts = [String: [String]]()
        for field in doc.keysAt(obj: .ROOT, heads: heads) where !reserved.contains(field) {
            let values = try doc.getAllAt(obj: .ROOT, key: field, heads: heads)
            if values.count > 1 { conflicts[field] = try values.map { try scalar($0, field: field) }.sorted() }
        }
        return try SyncMergeDetail(key: identity(doc), versions: versions, result: projection(doc, at: heads), conflicts: conflicts)
    }

    static func key(_ snapshot: Data) throws -> SyncRecordKey {
        try identity(Document(snapshot))
    }

    static func fields(_ snapshot: Data) throws -> SyncFields? {
        let doc = try Document(snapshot)
        _ = try identity(doc)
        return try projection(doc)
    }

    /// Each branch retains its exact projected version, even after a later edit supersedes it.
    static func history(_ snapshot: Data) throws -> [SyncDocumentRevision] {
        let doc = try Document(snapshot)
        _ = try identity(doc)
        return try doc.getHistory().map { hash in
            guard let change = doc.change(hash: hash) else { throw SyncDocumentError.invalidRecord }
            return try SyncDocumentRevision(
                changeID: hash.debugDescription,
                parents: change.deps.map(\.debugDescription).sorted(),
                fields: projection(doc, at: [hash]),
            )
        }
    }

    /// Concurrent register candidates at the current heads. The visible winner is in fields(_:).
    static func conflicts(_ snapshot: Data) throws -> [String: [String]] {
        let doc = try Document(snapshot)
        _ = try identity(doc)
        var result: [String: [String]] = [:]
        for name in doc.keys(obj: .ROOT) where !reserved.contains(name) {
            let values = try doc.getAll(obj: .ROOT, key: name)
            if values.count > 1 {
                result[name] = try values.map { try scalar($0, field: name) }.sorted()
            }
        }
        return result
    }

    static func validate(_ key: SyncRecordKey) throws {
        guard !key.kind.isEmpty, !key.kind.utf8.contains(where: { $0 < 32 }) else {
            throw SyncDocumentError.invalidRecord
        }
        try SyncWire.checkID(key.recordID)
    }

    private static func identity(_ doc: Document) throws -> SyncRecordKey {
        func identityField(_ name: String) throws -> String {
            let candidates = try doc.getAll(obj: .ROOT, key: name)
            guard candidates.count == 1, case let .Scalar(.String(value))? = candidates.first else {
                throw SyncDocumentError.invalidRecord
            }
            return value
        }
        let key = try SyncRecordKey(kind: identityField(kind), recordID: identityField(recordID))
        try validate(key)
        return key
    }

    private static func isDeleted(_ doc: Document) throws -> Bool {
        let values = try doc.getAll(obj: .ROOT, key: deleted)
        guard values.allSatisfy({ $0 == .Scalar(.String("true")) }) else { throw SyncDocumentError.invalidRecord }
        return !values.isEmpty
    }

    private static func projection(_ doc: Document, at heads: Set<ChangeHash>? = nil) throws -> SyncFields? {
        let entries: [(String, Value)] = if let heads {
            try doc.mapEntriesAt(obj: .ROOT, heads: heads)
        } else {
            try doc.mapEntries(obj: .ROOT)
        }
        var result = SyncFields()
        var tombstone = false
        for (name, value) in entries {
            switch name {
            case kind, recordID: continue
            case deleted:
                guard value == .Scalar(.String("true")) else { throw SyncDocumentError.invalidRecord }
                tombstone = true
            default:
                result[name] = try scalar(value, field: name)
            }
        }
        return tombstone ? nil : result
    }

    private static func scalar(_ value: Value, field: String) throws -> String {
        guard !reserved.contains(field), !field.isEmpty, case let .Scalar(.String(json)) = value else {
            throw SyncDocumentError.invalidField(field)
        }
        try validateJSON(json, field: field)
        return json
    }

    private static func validateJSON(_ json: String, field: String) throws {
        guard (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) != nil else {
            throw SyncDocumentError.invalidField(field)
        }
    }
}

nonisolated struct SyncMergeDetail: Sendable {
    let key: SyncRecordKey
    let versions: [SyncFields?]
    let result: SyncFields?
    let conflicts: [String: [String]]
}
