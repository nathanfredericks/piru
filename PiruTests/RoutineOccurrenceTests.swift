import Foundation
import SwiftData
import Testing

/// Noon today: inside the current journal day for any Day Starts At hour before noon, so the
/// suite never depends on the hour CI happens to run at.
private let suiteNow = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: .now)!
@testable import Piru

/// The occurrence test matrix, re-keyed by the Meds redesign:
/// per-slot materialization, the
/// matching rules with nearest-slot claims, re-derivation (edit/delete
/// robustness), sticky skips, end-of-day expiry, and the satisfied-slot gate
/// the follow-ups read.
@Suite("RoutineOccurrences", .serialized)
@MainActor
struct RoutineOccurrenceTests {
    /// A throwaway in-memory container. Each test must hold this for its
    /// whole body: a `ModelContext` does NOT retain its container, and an
    /// orphaned context traps (EXC_BREAKPOINT) on the first mutation — the
    /// lifetime rule documented on `UserProfileStore`.
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(PiruSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none),
        )
    }

    @discardableResult
    private func addItem(
        _ substance: String,
        times: [Int] = [9 * 60],
        route: RouteOfAdministration = .oral,
        uid: String? = nil,
        frequency: DoseFrequency = .daily,
        isAsNeeded: Bool = false,
        in context: ModelContext,
    ) -> DailyDoseItem {
        let item = DailyDoseItem(
            substance: substance, amount: 10, unit: "mg", route: route,
            reminderTimesMinutes: times, isAsNeeded: isAsNeeded,
        )
        item.substanceUID = uid
        item.frequency = frequency
        item.startDate = .distantPast
        context.insert(item)
        return item
    }

    @discardableResult
    private func addEntry(
        _ substance: String,
        route: RouteOfAdministration = .oral,
        uid: String? = nil,
        at timestamp: Date = suiteNow,
        in context: ModelContext,
    ) -> DoseEntry {
        let entry = DoseEntry(substance: substance, amount: 10, unit: "mg", route: route, substanceUID: uid, timestamp: timestamp)
        context.insert(entry)
        return entry
    }

    private func occurrences(in context: ModelContext) throws -> [RoutineOccurrence] {
        try context.fetch(FetchDescriptor<RoutineOccurrence>())
    }

    private func key(_ item: DailyDoseItem, slot: Int?) -> String {
        RoutineOccurrenceService.slotKey(
            substance: item.substance, substanceUID: item.substanceUID,
            route: item.route, slotMinutes: slot,
        )
    }

    // MARK: - Historical corrections

    @Test
    func `A past correction links a real dose after the schedule is deleted`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let calendar = Calendar.current
        let today = calendar.journalDay(for: suiteNow)
        let day = try #require(calendar.date(byAdding: .day, value: -2, to: today))
        let med = addItem("Testine", times: [540, 780], in: context)
        let occurrence = RoutineOccurrence(substance: "Testine", route: .oral, dueDay: day, slotMinutes: 540)
        occurrence.state = .missed
        context.insert(occurrence)
        context.delete(med)
        try context.save()

        let target = RoutineOccurrenceService.Correction(occurrence)
        let time = AdherenceCalculator.slotDate(minutes: 720, on: day)
        let entry = DoseEntry(substance: "Testine", amount: 7, timestamp: time, medSlotMinutes: 540)
        context.insert(entry)
        try RoutineOccurrenceService.stageTaken(target, by: entry, in: context, now: suiteNow)
        try context.save()

        let persisted = try #require(try occurrences(in: ModelContext(container)).first)
        #expect(persisted.state == .logged)
        #expect(persisted.satisfyingEntryID == entry.id)
        #expect(try occurrences(in: context).count == 1)
        #expect(RoutineOccurrenceService.satisfiedSlotKeys(in: context, now: suiteNow).isEmpty)
        #expect(throws: RoutineOccurrenceService.CorrectionError.occurrenceChanged) {
            try RoutineOccurrenceService.stageTaken(target, by: entry, in: context, now: suiteNow)
        }
    }

    @Test
    func `A past skip edits only the existing occurrence and clears back to missed`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let calendar = Calendar.current
        let today = calendar.journalDay(for: suiteNow)
        let day = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let row = RoutineOccurrence(substance: "Testine", route: .oral, dueDay: day)
        row.state = .missed
        context.insert(row)
        try context.save()
        let original = RoutineOccurrenceService.Correction(row)

        try RoutineOccurrenceService.setSkipped(true, for: original, in: context, now: suiteNow)
        #expect(row.state == .skipped)
        #expect(throws: RoutineOccurrenceService.CorrectionError.occurrenceChanged) {
            try RoutineOccurrenceService.setSkipped(true, for: original, in: context, now: suiteNow)
        }
        try RoutineOccurrenceService.setSkipped(false, for: .init(row), in: context, now: suiteNow)
        #expect(row.state == .missed)
        #expect(try context.fetchCount(FetchDescriptor<DoseEntry>()) == 0)
        #expect(try occurrences(in: context).count == 1)
    }

    @Test
    func `A missing linked dose cannot resolve to a similar entry or another store`() throws {
        let container = try makeContainer()
        let otherContainer = try makeContainer()
        let context = container.mainContext
        let daily = Calendar.current.journalDay(for: suiteNow)
        let row = RoutineOccurrence(substance: "Testine", route: .oral, dueDay: daily)
        row.state = .logged
        row.satisfyingEntryID = UUID()
        context.insert(row)
        let similar = addEntry("Testine", in: context)
        try context.save()
        let correction = RoutineOccurrenceService.Correction(row)

        #expect(throws: RoutineOccurrenceService.CorrectionError.occurrenceChanged) {
            _ = try RoutineOccurrenceService.linkedEntry(for: correction, in: context, now: suiteNow)
        }
        row.satisfyingEntryID = similar.id
        try context.save()
        #expect(try RoutineOccurrenceService.linkedEntry(for: .init(row), in: context, now: suiteNow).id == similar.id)
        #expect(throws: RoutineOccurrenceService.CorrectionError.occurrenceChanged) {
            _ = try RoutineOccurrenceService.linkedEntry(for: .init(row), in: otherContainer.mainContext, now: suiteNow)
        }
    }

    @Test
    func `A stale slot rolls back the entire checked dose batch`() async throws {
        await SubstanceStore.shared.ensureAllLoaded()
        let container = try makeContainer()
        let context = container.mainContext
        let calendar = Calendar.current
        let day = try #require(calendar.date(byAdding: .day, value: -1, to: calendar.journalDay(for: suiteNow)))
        let time = AdherenceCalculator.slotDate(minutes: 720, on: day)
        let first = RoutineOccurrence(substance: "First test med", route: .oral, dueDay: day)
        let second = RoutineOccurrence(substance: "Second test med", route: .oral, dueDay: day)
        first.state = .missed
        second.state = .missed
        context.insert(first)
        context.insert(second)
        try context.save()
        let corrections = [first, second].map(RoutineOccurrenceService.Correction.init)
        try RoutineOccurrenceService.setSkipped(true, for: corrections[1], in: context, now: suiteNow)

        let entries = [first.substance, second.substance].map { name in
            (entry: DoseEntry(substance: name, amount: 1, timestamp: time), substance: nil as Substance?)
        }
        #expect(throws: RoutineOccurrenceService.CorrectionError.occurrenceChanged) {
            _ = try DoseLogService.shared.checkedLogBatch(entries, colors: [], in: context, activatesLiveSession: false, beforeSave: { inserted in
                for (correction, entry) in zip(corrections, inserted) {
                    try RoutineOccurrenceService.stageTaken(correction, by: entry, in: context, now: suiteNow)
                }
            })
        }
        let savedContext = ModelContext(container)
        #expect(try savedContext.fetchCount(FetchDescriptor<DoseEntry>()) == 0)
        let saved = try occurrences(in: savedContext)
        #expect(saved.first(where: { $0.substance == first.substance })?.state == .missed)
        #expect(saved.first(where: { $0.substance == second.substance })?.state == .skipped)
        #expect(!context.hasChanges)
    }

    @Test
    func `Clearing a historical link leaves a similar dose and the next day alone`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let calendar = Calendar.current
        let today = calendar.journalDay(for: suiteNow)
        let day = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let time = AdherenceCalculator.slotDate(minutes: 720, on: day)
        let entry = addEntry("Testine", at: time, in: context)
        let similar = addEntry("Testine", at: time.addingTimeInterval(60), in: context)
        let row = RoutineOccurrence(substance: "Testine", route: .oral, dueDay: day)
        row.state = .logged
        row.satisfyingEntryID = entry.id
        context.insert(row)
        let next = RoutineOccurrence(substance: "Testine", route: .oral, dueDay: today)
        context.insert(next)
        try context.save()

        entry.timestamp = suiteNow
        try RoutineOccurrenceService.stageInvalidatedLinks(
            for: entry, deleting: false, movedBetweenDays: true, in: context, now: suiteNow,
        )
        try context.save()
        #expect(row.state == .missed)
        #expect(row.satisfyingEntryID == nil)
        #expect(next.state == .pending)
        #expect(!similar.isDeleted)
    }

    @Test
    func `An exact historical link survives a different journal day boundary`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let calendar = Calendar.current
        let time = suiteNow.addingTimeInterval(-3 * 86_400)
        let entry = addEntry("Testine", at: time, in: context)
        let recordedDay = try #require(calendar.date(byAdding: .day, value: -1, to: entry.journalDay()))
        let occurrence = RoutineOccurrence(substance: "Testine", route: .oral, dueDay: recordedDay)
        occurrence.state = .logged
        occurrence.satisfyingEntryID = entry.id
        context.insert(occurrence)
        try context.save()

        let linked = try RoutineOccurrenceService.linkedEntry(for: .init(occurrence), in: context, now: suiteNow)
        #expect(linked.id == entry.id)
    }

    @Test
    func `Removal requires confirmation of the exact linked dose`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let calendar = Calendar.current
        let day = try #require(calendar.date(byAdding: .day, value: -1, to: calendar.journalDay(for: suiteNow)))
        let time = AdherenceCalculator.slotDate(minutes: 720, on: day)
        let entry = addEntry("Testine", at: time, in: context)
        let other = addEntry("Testine", at: time, in: context)
        let row = RoutineOccurrence(substance: "Testine", route: .oral, dueDay: day)
        row.state = .logged
        row.satisfyingEntryID = entry.id
        context.insert(row)
        try context.save()

        #expect(throws: RoutineOccurrenceService.CorrectionError.occurrenceChanged) {
            try SessionEditingService.shared.deleteOccurrenceDose(.init(row), in: context) { $0.id == other.id }
        }
        #expect(try context.fetchCount(FetchDescriptor<DoseEntry>()) == 2)
        #expect(row.satisfyingEntryID == entry.id)

        let confirmedID = entry.id
        try SessionEditingService.shared.deleteOccurrenceDose(.init(row), in: context) { $0.id == confirmedID }
        #expect(try context.fetch(FetchDescriptor<DoseEntry>()).map(\.id) == [other.id])
        #expect(row.state == .missed)
        #expect(row.satisfyingEntryID == nil)
    }

    @Test
    func `Today reconciliation keeps the checked dose when there is a competing dose`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let slot = 9 * 60
        addItem("Testine", times: [slot], in: context)
        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        let row = try #require(try occurrences(in: context).first)
        let time = AdherenceCalculator.slotDate(minutes: slot, on: row.dueDay)
        let earlier = addEntry("Testine", at: time.addingTimeInterval(-60), in: context)
        earlier.medSlotMinutes = slot
        let checked = addEntry("Testine", at: time, in: context)
        checked.medSlotMinutes = slot

        let now = max(suiteNow, time)
        try RoutineOccurrenceService.stageTaken(.init(row), by: checked, in: context, now: now)
        try context.save()
        RoutineOccurrenceService.reconcile(in: context, now: now)
        #expect(row.satisfyingEntryID == checked.id)
    }

    // MARK: - Materialization

    @Test
    func `Due items get one occurrence per slot; off-schedule items don't; reruns are idempotent`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        addItem("Methylphenidate", times: [8 * 60, 13 * 60], in: context)
        // Weekly item off its cycle day — no occurrence today.
        let weekly = addItem("B12", frequency: .weekly, in: context)
        weekly.startDate = try #require(Calendar.current.date(byAdding: .day, value: -3, to: suiteNow))

        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        let first = try occurrences(in: context)
        #expect(first.count == 2)
        #expect(Set(first.map(\.slotMinutes)) == [8 * 60, 13 * 60])
        #expect(first.allSatisfy { $0.state == .pending })

        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        #expect(try occurrences(in: context).count == 2)
    }

    @Test
    func `A med with no set times gets a single anytime slot`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        addItem("Vitamin D3", times: [], in: context)
        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        let all = try occurrences(in: context)
        #expect(all.count == 1)
        #expect(all.first?.slotMinutes == nil)
    }

    @Test
    func `As-needed meds get no occurrences`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        addItem("Ibuprofen", times: [], isAsNeeded: true, in: context)
        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        #expect(try occurrences(in: context).isEmpty)
    }

    // MARK: - Matching (§D)

    @Test
    func `A logged dose satisfies its occurrence by name`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        addItem("Vitamin D3", in: context)
        let entry = addEntry("vitamin d3", in: context)

        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        let occurrence = try #require(try occurrences(in: context).first)
        #expect(occurrence.state == .logged)
        #expect(occurrence.satisfyingEntryID == entry.id)
    }

    @Test
    func `Identity matching prefers substanceUID over the name`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        addItem("Concerta", uid: "psid:mph", in: context)
        // Relabeled dose: different name, same identity (spec §D — a relabel
        // doesn't break the match).
        addEntry("Methylphenidate XR", uid: "psid:mph", in: context)

        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        #expect(try occurrences(in: context).first?.state == .logged)
    }

    @Test
    func `A re-pinned PSID still matches by name, so the checklist agrees with the Log sheet`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        // The med was scheduled against one PSID family and the dose logged
        // against the family it was re-pinned to. The quick-log chips credit
        // this by name; the checklist must too, or one screen reads 0/1 while
        // the other shows a tick.
        addItem("Methylphenidate", uid: "psid:41276", in: context)
        let entry = addEntry("Methylphenidate", uid: "psid:4158", in: context)

        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        let occurrence = try #require(try occurrences(in: context).first)
        #expect(occurrence.state == .logged)
        #expect(occurrence.satisfyingEntryID == entry.id)
        #expect(try AdherenceCalculator.entryMatches(entry: entry, item: #require(
            try context.fetch(FetchDescriptor<DailyDoseItem>()).first,
        )))
    }

    @Test
    func `A route mismatch does not match`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        addItem("Melatonin", route: .oral, in: context)
        addEntry("Melatonin", route: .sublingual, in: context)

        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        #expect(try occurrences(in: context).first?.state == .pending)
    }

    @Test
    func `One entry claims the nearest slot; a second entry fills the other`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let calendar = Calendar.current
        addItem("Methylphenidate", times: [8 * 60, 22 * 60], in: context)

        let morning = try #require(calendar.date(bySettingHour: 8, minute: 10, second: 0, of: suiteNow))
        addEntry("Methylphenidate", at: morning, in: context)

        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        var all = try occurrences(in: context)
        #expect(all.count == 2)
        #expect(all.first { $0.slotMinutes == 8 * 60 }?.state == .logged)
        #expect(all.first { $0.slotMinutes == 22 * 60 }?.state == .pending)

        let night = try #require(calendar.date(bySettingHour: 21, minute: 45, second: 0, of: suiteNow))
        addEntry("Methylphenidate", at: night, in: context)
        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        all = try occurrences(in: context)
        #expect(all.allSatisfy { $0.state == .logged })
    }

    @Test
    func `An ad-hoc dose matching nothing claims nothing`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        addItem("Vitamin D3", in: context)
        addEntry("Caffeine", in: context)

        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        #expect(try occurrences(in: context).first?.state == .pending)
    }

    // MARK: - Re-derivation

    @Test
    func `Deleting the satisfying dose returns the occurrence to pending`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        addItem("Vitamin D3", in: context)
        let entry = addEntry("Vitamin D3", in: context)

        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        #expect(try occurrences(in: context).first?.state == .logged)

        context.delete(entry)
        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        let occurrence = try #require(try occurrences(in: context).first)
        #expect(occurrence.state == .pending)
        #expect(occurrence.satisfyingEntryID == nil)
    }

    @Test
    func `Removing a reminder time drops its pending occurrence`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = addItem("Methylphenidate", times: [8 * 60, 13 * 60], in: context)

        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        #expect(try occurrences(in: context).count == 2)

        item.reminderTimesMinutes = [8 * 60]
        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        let all = try occurrences(in: context)
        #expect(all.count == 1)
        #expect(all.first?.slotMinutes == 8 * 60)
    }

    @Test
    func `Skipped is sticky through reconciles and matching`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = addItem("Vitamin D3", in: context)

        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        RoutineOccurrenceService.skipToday(slotKeys: [key(item, slot: 9 * 60)], in: context, now: suiteNow)
        #expect(try occurrences(in: context).first?.state == .skipped)

        // Neither a plain reconcile nor a matching dose reclaims it.
        addEntry("Vitamin D3", in: context)
        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        #expect(try occurrences(in: context).first?.state == .skipped)
    }

    // MARK: - Expiry

    @Test
    func `Yesterday's pending expires to missed; history states survive`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: suiteNow)))
        let stale = RoutineOccurrence(substance: "Vitamin D3", route: .oral, dueDay: yesterday, slotMinutes: 9 * 60)
        let done = RoutineOccurrence(substance: "Magnesium", route: .oral, dueDay: yesterday, slotMinutes: 9 * 60)
        done.state = .logged
        context.insert(stale)
        context.insert(done)

        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        #expect(stale.state == .missed)
        #expect(done.state == .logged)
    }

    // MARK: - The follow-up gate

    @Test
    func `Satisfied slot keys cover logged and skipped, not pending`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let d3 = addItem("Vitamin D3", times: [9 * 60], in: context)
        let mag = addItem("Magnesium", times: [21 * 60], in: context)
        addEntry("Vitamin D3", in: context)

        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        var satisfied = RoutineOccurrenceService.satisfiedSlotKeys(in: context, now: suiteNow)
        #expect(satisfied.contains(key(d3, slot: 9 * 60)))
        #expect(!satisfied.contains(key(mag, slot: 21 * 60)))

        RoutineOccurrenceService.skipToday(slotKeys: [key(mag, slot: 21 * 60)], in: context, now: suiteNow)
        satisfied = RoutineOccurrenceService.satisfiedSlotKeys(in: context, now: suiteNow)
        #expect(satisfied.contains(key(mag, slot: 21 * 60)))
    }

    @Test
    func `A multi-time med is satisfied per slot, not per med`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let calendar = Calendar.current
        let item = addItem("Methylphenidate", times: [8 * 60, 13 * 60], in: context)
        let morning = try #require(calendar.date(bySettingHour: 8, minute: 5, second: 0, of: suiteNow))
        addEntry("Methylphenidate", at: morning, in: context)

        RoutineOccurrenceService.reconcile(in: context, now: suiteNow)
        let satisfied = RoutineOccurrenceService.satisfiedSlotKeys(in: context, now: suiteNow)
        #expect(satisfied.contains(key(item, slot: 8 * 60)))
        #expect(!satisfied.contains(key(item, slot: 13 * 60)))
    }
}
