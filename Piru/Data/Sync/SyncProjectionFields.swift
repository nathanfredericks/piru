import Foundation
import SwiftData

extension SyncField {
    /// One Automerge scalar for values whose units or meaning depend on each other.
    /// Omitted optional members clear to null. Explicit defaults support older SDK writers.
    static func group(
        _ name: String, _ members: [Self], required: Set<String>,
        defaults: [String: String] = [:],
    ) -> Self {
        let sorted = members.sorted { $0.name < $1.name }
        return Self(name, read: { row in
            let parts = try sorted.map { member in
                try SyncJSON.encode(member.name) + ":" + (member.read(row) ?? "null")
            }
            return "{" + parts.joined(separator: ",") + "}"
        }, prepare: { json, context in
            guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  required.isSubset(of: object.keys) else { throw SyncProjectionError.invalidField(name) }
            let setters = try members.map { member in
                let raw: String = if let value = object[member.name] {
                    try SyncJSON.utf8(JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]))
                } else {
                    defaults[member.name] ?? "null"
                }
                return try member.prepare(raw, context)
            }
            return { row in
                for set in setters { set(row) }
            }
        })
    }
}

extension SyncProjection {
    static func reference<Row>(_ name: String, _ path: ReferenceWritableKeyPath<Row, UUID?>) -> SyncField<Row> {
        SyncField(name, read: { row in try SyncJSON.encode(row[keyPath: path]?.uuidString.lowercased()) }, prepare: { json, _ in
            let id = try decodeReference(json)
            return { $0[keyPath: path] = id }
        })
    }

    static func decodeReference(_ json: String) throws -> UUID? {
        guard let string = try SyncJSON.decode(String?.self, from: json) else { return nil }
        guard let id = UUID(uuidString: string), id.uuidString.lowercased() == string else {
            throw SyncProjectionError.invalidField("UUID")
        }
        return id
    }

    static func sessionLink<Row>(
        _ link: ReferenceWritableKeyPath<Row, Session?>, pending: ReferenceWritableKeyPath<Row, UUID?>,
    ) -> SyncField<Row> {
        SyncField("sessionID", required: false, read: { row in
            let id = row[keyPath: link]?.id ?? row[keyPath: pending]
            return try SyncJSON.encode(id?.uuidString.lowercased())
        }, prepare: { json, context in
            let id = try decodeReference(json)
            let parent = try id.flatMap { id in
                var request = FetchDescriptor<Session>(predicate: #Predicate { $0.id == id })
                request.fetchLimit = 1
                return try context.fetch(request).first
            }
            return { row in
                let previous = row[keyPath: link]
                row[keyPath: link] = parent
                row[keyPath: pending] = parent == nil ? id : nil
                if previous !== parent { previous?.refreshDoseBounds() }
            }
        })
    }

    static func attachWaitingChildren(_ session: Session, in context: ModelContext) throws {
        let id = session.id
        for dose in try context.fetch(FetchDescriptor<DoseEntry>(predicate: #Predicate { $0.pendingSyncSessionID == id })) {
            if dose.session == nil { dose.session = session }
            dose.pendingSyncSessionID = nil
        }
        for note in try context.fetch(FetchDescriptor<SessionNote>(predicate: #Predicate { $0.pendingSyncSessionID == id })) {
            if note.session == nil { note.session = session }
            note.pendingSyncSessionID = nil
        }
        session.refreshDoseBounds()
    }

    /// A session tombstone owns only the parent. Each child has an independent document
    /// and may already have a concurrent move or an outstanding deletion of its own.
    static func detachSession(_ session: Session) {
        for dose in session.doses ?? [] {
            dose.pendingSyncSessionID = session.id
            dose.session = nil
        }
        for note in session.notes ?? [] {
            note.pendingSyncSessionID = session.id
            note.session = nil
        }
    }

    static let manualWeight = SyncField<UserProfileRecord>("manualWeightKg", required: false, read: { row in
        guard row.weightSourceRaw == "manual" || row.weightSourceRaw == "estimated" else { return nil }
        return try SyncJSON.encode(row.weightSourceRaw == "manual" ? row.bodyWeightKg : nil)
    }, prepare: { json, _ in
        let kg = try SyncJSON.decode(Double?.self, from: json)
        if let kg, !UserProfileStore.weightRangeKg.contains(kg) { throw SyncProjectionError.invalidField("manualWeightKg") }
        return { row in
            guard row.weightSourceRaw != "healthKit" else { return }
            row.bodyWeightKg = kg
            row.weightSourceRaw = kg == nil ? "estimated" : "manual"
        }
    })

    static let askAgainCadence = SyncField<NotificationPreferences>("askAgainDefaultMinutes", get: {
        $0.askAgainDefaultData.isEmpty ? nil : $0.askAgainDefaultMinutes
    }, set: { row, value in
        if let value { row.askAgainDefaultMinutes = value } else { row.askAgainDefaultData = Data() }
    })

    static let colorChoice = SyncField<SubstanceColor>("color", read: { row in
        let tint = row.tint
        return try SyncJSON.encode([tint.red, tint.green, tint.blue])
    }, prepare: { json, _ in
        let rgb = try SyncJSON.decode([Double].self, from: json)
        guard rgb.count == 3, rgb.allSatisfy({ (0 ... 1).contains($0) }) else { throw SyncProjectionError.invalidField("color") }
        let tint = P3Color(red: rgb[0], green: rgb[1], blue: rgb[2])
        return { $0.set(tint, usesDefault: false) }
    })

    static func blob<Row, Value: Codable>(
        _ name: String, _ path: ReferenceWritableKeyPath<Row, Data?>, as _: Value.Type,
    ) -> SyncField<Row> {
        SyncField(name, read: { row in
            let value = try row[keyPath: path].map { try JSONDecoder().decode(Value.self, from: $0) }
            return try SyncJSON.encode(value)
        }, prepare: { json, _ in
            let value = try SyncJSON.decode(Value?.self, from: json)
            let data = try value.map { try SyncJSON.encoder().encode($0) }
            return { $0[keyPath: path] = data }
        })
    }

    /// Concurrent restocks update distinct Automerge map keys. A missing event in a complete
    /// materialized document removes it. The event ID lives in the key exactly once.
    private struct StockEvent: Codable {
        var kind: ManualEvent.Kind
        var amount: Double
        var date: Date
        var note: String?
        var setsBaseline: Bool
    }

    static func inventoryEvents(_ row: InventoryItem) throws -> SyncFields {
        var fields: SyncFields = [:]
        for event in row.manualEvents {
            let key = "event." + event.id.uuidString.lowercased()
            guard fields[key] == nil else { throw SyncProjectionError.duplicateIdentity(key) }
            fields[key] = try SyncJSON.encode(StockEvent(
                kind: event.kind,
                amount: event.amount,
                date: event.date,
                note: event.note,
                setsBaseline: event.setsBaseline,
            ))
        }
        return fields
    }

    static func prepareInventoryEvents(_ fields: SyncFields) throws -> (InventoryItem) -> Void {
        var events: [ManualEvent] = []
        for (key, raw) in fields where key.hasPrefix("event.") {
            let str = String(key.dropFirst(6))
            guard let id = UUID(uuidString: str), id.uuidString.lowercased() == str else {
                throw SyncProjectionError.invalidField(key)
            }
            let value = try SyncJSON.decode(StockEvent.self, from: raw)
            events.append(ManualEvent(
                id: id,
                kind: value.kind,
                amount: value.amount,
                date: value.date,
                note: value.note,
                setsBaseline: value.setsBaseline,
            ))
        }
        let ordered = events.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
        return { $0.manualEvents = ordered }
    }
}
