import Foundation
import SwiftData
import Testing
@testable import Piru

@Suite("Durable journal sync projection")
@MainActor
struct SyncProjectionTests {
    @Test
    func `complete profile round trip and independent stock events`() throws {
        let (source, sourceURL) = try makeScratchProfileDirectory()
        let (target, targetURL) = try makeScratchProfileDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let context = source.activeContainer.mainContext
        let destination = target.activeContainer.mainContext
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let session = Session(startDate: time, title: "Journal")
        let dose = DoseEntry(
            substance: "Custom",
            amount: 5,
            unit: "drops",
            timestamp: time,
            notes: "Written as typed",
            latitude: 12,
            longitude: 34,
            volumeML: 5,
            abv: 10,
        )
        let note = SessionNote(timestamp: time, text: "authored", heartRate: 76, session: session)
        let stock = InventoryItem(substance: "Custom", manualEvents: [ManualEvent(amount: 3), ManualEvent(amount: 4)])
        let custom = CustomSubstanceRecord(name: "Custom", displayName: "Bottle", notes: "custom")
        let med = DailyDoseItem(substance: "Custom", amount: 5, category: "Morning", reminderTimesMinutes: [480])
        let occurrence = RoutineOccurrence(routineName: "Morning", substance: "Custom", route: .oral, dueDay: time)
        dose.session = session
        occurrence.satisfyingEntryID = dose.id
        session.sharedExperienceID = UUID()
        stock.sharedWith = [UUID()]
        stock.currentQuantity = 999
        context.insert(session)
        context.insert(dose)
        context.insert(note)
        context.insert(stock)
        context.insert(custom)
        context.insert(med)
        context.insert(occurrence)
        context.insert(DoseRoutine(name: "Morning"))
        context.insert(FavoriteSubstance(substance: "Custom"))
        context.insert(SubstanceColor(substance: "Custom", tint: .neutral, usesDefault: false))
        context.insert(QuickLogDose(substance: "Custom", route: .oral, amount: 1, unit: "drops", sortOrder: 0))
        context.insert(CustomUnitPreset(substanceName: "Custom", label: "drop", amountPerUnit: 2))
        context.insert(CustomDrinkPreset(name: "Bottle", strengthABV: 10))
        context.insert(UserProfileRecord(bodyWeightKg: 64, weightSourceRaw: "manual"))
        context.insert(NotificationPreferences())
        context.insert(LabMeasurement(value: 2, note: "authored lab"))
        context.insert(ToleranceState(target: "derived"))
        try context.save()
        let records = try SyncProjection.records(in: context, profileID: source.owner.id, directory: nil)
        #expect(Set(records.keys.map(\.kind)) == [
            "dose", "session", "sessionNote", "inventoryItem", "customSubstance", "dailyDoseItem",
            "routineOccurrence", "doseRoutine", "favorite", "substanceColor", "quickLogDose",
            "customUnit", "customDrink", "userProfile", "notificationPreferences", "labMeasurement",
        ])
        let doseFields = try #require(records[SyncRecordKey(kind: "dose", id: dose.id)])
        #expect(doseFields["dose"]?.contains("\"volumeML\":5") == true)
        #expect(doseFields["amount"] == nil)
        #expect(doseFields["latitude"] == nil)
        let stockFields = try #require(records[SyncRecordKey(kind: "inventoryItem", id: stock.id)])
        #expect(stockFields.keys.filter { $0.hasPrefix("event.") }.count == 2)
        #expect(stockFields["sharedWith"] == nil)
        #expect(stockFields["currentQuantity"] == nil)
        // Each child commits before its parent, just as it can across feed pages.
        let sessionKey = SyncRecordKey(kind: "session", id: session.id)
        for (key, fields) in records where key != sessionKey {
            try SyncProjection.apply(key, fields: fields, in: destination, profileID: target.owner.id)
        }
        try destination.save()
        let waiting = try #require(try destination.fetch(FetchDescriptor<DoseEntry>()).first)
        #expect(waiting.session == nil)
        #expect(waiting.pendingSyncSessionID == session.id)
        try SyncProjection.apply(sessionKey, fields: records[sessionKey], in: destination, profileID: target.owner.id)
        try destination.save()
        #expect(waiting.session?.id == session.id)
        #expect(waiting.pendingSyncSessionID == nil)
        let actual = try SyncProjection.records(in: destination, profileID: target.owner.id, directory: nil)
        #expect(actual == records)
        try SyncProjection.apply(sessionKey, fields: nil, in: destination, profileID: target.owner.id)
        try destination.save()
        let surviving = try #require(try destination.fetch(FetchDescriptor<SessionNote>()).first)
        #expect(surviving.pendingSyncSessionID == session.id)
        #expect(surviving.text == "authored")
    }

    @Test
    func `remote edits preserve excluded fields and validate before mutation`() throws {
        let (directory, url) = try makeScratchProfileDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        let profile = directory.owner.id
        let context = directory.activeContainer.mainContext
        let note = SessionNote(text: "old", heartRate: 80)
        let prefs = UserProfileRecord(bodyWeightKg: 72, weightSourceRaw: "healthKit")
        let dose = DoseEntry(substance: "A", amount: 1, locationName: "home")
        context.insert(note)
        context.insert(prefs)
        context.insert(dose)
        try context.save()
        let noteKey = SyncRecordKey(kind: "sessionNote", id: note.id)
        try SyncProjection.apply(noteKey, fields: ["text": "\"edited\"", "heartRate": "33"], in: context, profileID: profile)
        #expect(note.text == "edited" && note.heartRate == 80)
        let profileKey = SyncRecordKey(kind: "userProfile", id: SyncProjection.singletonID)
        try SyncProjection.apply(profileKey, fields: ["manualWeightKg": "60"], in: context, profileID: profile)
        #expect(prefs.bodyWeightKg == 72 && prefs.weightSourceRaw == "healthKit")
        let fields = try #require(try SyncProjection.fields(for: profileKey, in: context, profileID: profile))
        #expect(fields["manualWeightKg"] == nil)
        let key = SyncRecordKey(kind: "dose", id: dose.id)
        try SyncProjection.apply(key, fields: ["dose": #"{"substance":"A","route":"oral","amount":2,"unit":"g"}"#], in: context, profileID: profile)
        #expect(dose.amount == 2 && dose.unit == "g" && dose.locationName == "home")
        #expect(throws: (any Error).self) {
            try SyncProjection.apply(key, fields: ["notes": "\"bad edit\"", "dose": #"{"amount":99}"#], in: context, profileID: profile)
        }
        #expect(dose.amount == 2 && dose.notes == nil)
    }

    @Test
    func `editable IDs survive rename and hard delete history`() throws {
        let (directory, url) = try makeScratchProfileDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        let context = directory.activeContainer.mainContext
        let unit = CustomUnitPreset(substanceName: "A", label: "drop", amountPerUnit: 2)
        context.insert(unit)
        try context.save()
        try SyncProjection.backfillStableIDs(in: context)
        let id = try #require(unit.syncID)
        let key = SyncRecordKey(kind: "customUnit", id: id)
        try context.save()
        unit.label = "scoop"
        try context.save()
        let last = try #require(try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()).last)
        let keys = try last.changes.compactMap { try SyncProjection.recordKey(for: $0, in: context, profileID: directory.owner.id) }
        #expect(keys.contains(key))
        let fields = try SyncProjection.fields(for: key, in: context, profileID: directory.owner.id)
        #expect(fields?["label"] == "\"scoop\"")
        context.delete(unit)
        try context.save()
        let history = try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
        let deleted = try history.flatMap(\.changes).compactMap { change -> SyncRecordKey? in
            guard case .delete = change else { return nil }
            return try SyncProjection.recordKey(for: change, in: context, profileID: directory.owner.id)
        }
        #expect(deleted.contains(key))
        #expect(try SyncProjection.fields(for: key, in: context, profileID: directory.owner.id) == nil)
        let replacement = CustomUnitPreset(substanceName: "A", label: "drop", amountPerUnit: 3)
        context.insert(replacement)
        try context.save()
        try SyncProjection.backfillStableIDs(in: context)
        #expect(replacement.syncID == id)
        let successor = try #require(try SyncProjection.renewIdentity(for: key, in: context))
        try context.save()
        #expect(successor != key)
        #expect(replacement.syncID?.uuidString.lowercased() == successor.recordID)
        #expect(try SyncProjection.fields(for: key, in: context, profileID: directory.owner.id) == nil)
        #expect(try SyncProjection.fields(for: successor, in: context, profileID: directory.owner.id) != nil)
    }
}
