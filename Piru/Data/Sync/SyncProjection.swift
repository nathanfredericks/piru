import CryptoKit
import Foundation
import SwiftData

nonisolated struct SyncRecordKey: Hashable, Codable, Sendable {
    let kind: String
    let recordID: String

    init(kind: String, recordID: String) {
        self.kind = kind
        self.recordID = recordID
    }

    init(kind: String, id: UUID) {
        self.init(kind: kind, recordID: id.uuidString.lowercased())
    }
}

typealias SyncFields = [String: String]

enum SyncProjectionError: Error, Equatable {
    case invalidKey(SyncRecordKey)
    case invalidField(String)
    case missingField(String)
    case duplicateIdentity(String)
    case unknownProfile(UUID)
    case missingPhoto
}

@MainActor
enum SyncProjection {
    /// Singleton documents have a fixed ID even when a cloud journal binds to different local profile IDs.
    static let singletonID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    static func records(in context: ModelContext, profileID: UUID) throws -> [SyncRecordKey: SyncFields] {
        try records(in: context, profileID: profileID, directory: .shared)
    }

    static func records(in context: ModelContext, profileID: UUID, directory: ProfileDirectory?) throws -> [SyncRecordKey: SyncFields] {
        var result: [SyncRecordKey: SyncFields] = [:]
        try forEachRecord(in: context, profileID: profileID, directory: directory) { key, fields in
            guard result.updateValue(fields, forKey: key) == nil else { throw SyncProjectionError.duplicateIdentity(key.kind) }
        }
        return result
    }

    static func forEachRecord(
        in context: ModelContext, profileID: UUID,
        _ visit: (SyncRecordKey, SyncFields) throws -> Void,
    ) throws {
        try forEachRecord(in: context, profileID: profileID, directory: .shared, visit)
    }

    static func forEachRecord(
        in context: ModelContext, profileID: UUID, directory: ProfileDirectory?,
        _ visit: (SyncRecordKey, SyncFields) throws -> Void,
    ) throws {
        if let directory {
            for (key, fields) in try metadataRecords(profileID: profileID, directory: directory) {
                try visit(key, fields)
            }
        }
        for table in tables { try table.forEachRecord(in: context, visit) }
    }

    /// Run before bootstrap or the first remote apply to a populated store. The caller saves.
    static func backfillStableIDs(in context: ModelContext) throws {
        for table in tables {
            try table.backfill(in: context)
        }
    }

    /// Map a single SwiftData history change, including hard deletes. A later delete can
    /// make an earlier insert/update unresolvable; its own history change carries the key.
    static func recordKey(for change: HistoryChange, in context: ModelContext, profileID _: UUID) throws -> SyncRecordKey? {
        let pid = change.changedPersistentIdentifier
        guard let table = tablesByEntity[pid.entityName] else { return nil }
        if case let .delete(deletion) = change {
            return table.deletedKey(deletion)
        }
        return try table.liveKey(pid, in: context)
    }

    static func fields(for key: SyncRecordKey, in context: ModelContext, profileID: UUID) throws -> SyncFields? {
        try fields(for: key, in: context, profileID: profileID, directory: nil)
    }

    static func fields(for key: SyncRecordKey, in context: ModelContext, profileID: UUID, directory: ProfileDirectory?) throws -> SyncFields? {
        if key.kind == avatarAssetKind {
            return try avatarAssetFields(key, profileID: profileID, directory: directory ?? .shared)
        }
        if key.kind == metadataKind {
            try validateMetadataKey(key)
            return try metadataRecords(profileID: profileID, directory: directory, includeAsset: { _ in false })[key]
        }
        let (table, id) = try resolve(key)
        return try table.fields(id: id, in: context)
    }

    /// A fresh incarnation of an editable row recreated after its last document was tombstoned.
    /// Existing journal UUIDs and singleton IDs are permanent and cannot be renewed.
    static func renewIdentity(for key: SyncRecordKey, in context: ModelContext) throws -> SyncRecordKey? {
        if key.kind == metadataKind || key.kind == avatarAssetKind { return nil }
        let (table, id) = try resolve(key)
        return try table.renewIdentity(id: id, in: context)
    }

    /// Receives the complete materialized document, or nil for a tombstone. The caller owns
    /// the transaction, rollback, and post-commit refresh. This layer schedules no notifications.
    static func apply(_ key: SyncRecordKey, fields: SyncFields?, in context: ModelContext, profileID: UUID) throws {
        try apply(key, fields: fields, in: context, profileID: profileID, directory: nil)
    }

    static func apply(_ key: SyncRecordKey, fields: SyncFields?, in context: ModelContext, profileID: UUID, directory: ProfileDirectory?) throws {
        if key.kind == avatarAssetKind {
            try applyAvatarAsset(key, fields: fields, profileID: profileID, directory: directory ?? .shared)
            return
        }
        if key.kind == metadataKind {
            try applyMetadata(key, fields: fields, profileID: profileID, directory: directory)
            return
        }
        let (table, id) = try resolve(key)
        try table.apply(id: id, fields: fields, in: context)
    }

    private static func resolve(_ key: SyncRecordKey) throws -> (any SyncModelTable, UUID) {
        guard let table = tablesByKind[key.kind], let id = UUID(uuidString: key.recordID),
              id.uuidString.lowercased() == key.recordID, !table.singleton || id == singletonID else {
            throw SyncProjectionError.invalidKey(key)
        }
        return (table, id)
    }

    static func stableID(_ kind: String, parts: [String]) throws -> UUID {
        // Length-delimited by JSON to keep arbitrary authored names unambiguous.
        let bytes = try SyncJSON.encoder().encode(["piru-sync-id-v1", kind] + parts)
        return hashUUID(SHA256.hash(data: bytes))
    }

    static func hashUUID(_ hash: SHA256.Digest) -> UUID {
        var digest = Array(hash.prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x80
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0],
            digest[1],
            digest[2],
            digest[3],
            digest[4],
            digest[5],
            digest[6],
            digest[7],
            digest[8],
            digest[9],
            digest[10],
            digest[11],
            digest[12],
            digest[13],
            digest[14],
            digest[15],
        ))
    }

    static let tablesByKind = Dictionary(uniqueKeysWithValues: tables.map { ($0.kind, $0) })
    static let tablesByEntity = Dictionary(uniqueKeysWithValues: tables.map { ($0.entity, $0) })
}

@MainActor
enum SyncJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
            guard let value = Int64(exactly: milliseconds) else { throw SyncProjectionError.invalidField("date") }
            try container.encode(value)
        }
        return encoder
    }

    static func encode(_ value: some Encodable) throws -> String {
        try utf8(encoder().encode(value))
    }

    static func utf8(_ data: Data) throws -> String {
        guard let json = String(bytes: data, encoding: .utf8) else { throw SyncProjectionError.invalidField("JSON") }
        return json
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: Data(json.utf8))
    }
}
