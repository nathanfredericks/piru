import Foundation
import SwiftData
import Testing
@testable import Piru

/// The composed batch pipeline behind every multi-dose logging surface
/// (quick-log tray, both daily-med sites): insert → session assignment →
/// first-time color → one commit → change signal. The stages have their own
/// suites (SessionServiceTests, the QuickLog suites); this one pins the
/// composition.
@MainActor
@Suite("DoseLogBatch")
struct DoseLogBatchTests {
    /// An in-memory store with the full current schema.
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema(PiruSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none),
        )
        return ModelContext(container)
    }

    /// Absent from the substance library, so the tests are independent of
    /// bundled data.
    private let unknown = "ZZBatchTestSubstance"

    private func entry(_ substance: String, hoursFromNow: Double = 0) -> DoseEntry {
        DoseEntry(
            substance: substance,
            amount: 100,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(hoursFromNow * 3_600),
        )
    }

    @Test
    func `Batch inserts every dose with a session assigned, in one commit`() throws {
        let context = try makeContext()
        let doses: [(entry: DoseEntry, substance: Substance?)] = [
            (entry(unknown), nil),
            (entry(unknown, hoursFromNow: 1), nil),
        ]

        DoseLogService.shared.logBatch(doses, colors: [], in: context)

        let saved = try context.fetch(FetchDescriptor<DoseEntry>())
        #expect(saved.count == 2)
        for dose in saved {
            #expect(dose.session != nil)
        }
        // Close doses share one session; the single commit left nothing pending.
        #expect(try context.fetch(FetchDescriptor<Session>()).count == 1)
        #expect(!context.hasChanges)
    }

    @Test
    func `First-time substance gets exactly one class-color row`() throws {
        let context = try makeContext()
        let doses: [(entry: DoseEntry, substance: Substance?)] = [
            (entry(unknown), nil),
            (entry(unknown, hoursFromNow: 0.5), nil),
        ]

        DoseLogService.shared.logBatch(doses, colors: [], in: context)

        let colors = try context.fetch(FetchDescriptor<SubstanceColor>())
        #expect(colors.count == 1)
        #expect(colors.first?.substance == unknown)
        #expect(colors.first?.usesDefault == true)
        #expect(colors.first?.tint == SubstanceColorStore.defaultTint(for: unknown))
    }

    @Test
    func `An already-colored substance mints no duplicate`() throws {
        let context = try makeContext()
        let existing = SubstanceColor(substance: unknown, tint: .neutral, usesDefault: false)
        context.insert(existing)
        try context.save()

        DoseLogService.shared.logBatch([(entry(unknown), nil)], colors: [existing], in: context)

        #expect(try context.fetch(FetchDescriptor<SubstanceColor>()).count == 1)
    }

    @Test
    func `Revision bumps exactly once per batch`() throws {
        let context = try makeContext()
        let before = DoseLogService.shared.revision

        DoseLogService.shared.logBatch(
            [(entry(unknown), nil), (entry(unknown, hoursFromNow: 1), nil)],
            colors: [],
            in: context,
        )

        #expect(DoseLogService.shared.revision == before + 1)
    }

    @Test
    func `beforeSave mutations ride the same commit`() throws {
        let context = try makeContext()

        DoseLogService.shared.logBatch(
            [(entry(unknown), nil)],
            colors: [],
            in: context,
            beforeSave: {
                context.insert(DailyDoseItem(substance: unknown, amount: 10))
            },
        )

        #expect(try context.fetch(FetchDescriptor<DailyDoseItem>()).count == 1)
        #expect(!context.hasChanges)
    }

    @Test
    func `Empty batch is a complete no-op`() throws {
        let context = try makeContext()
        let before = DoseLogService.shared.revision

        DoseLogService.shared.logBatch([], colors: [], in: context)

        #expect(DoseLogService.shared.revision == before)
        #expect(try context.fetch(FetchDescriptor<DoseEntry>()).isEmpty)
        #expect(!context.hasChanges)
    }

    /// The tray commits a combination as one entry per component, each
    /// carrying the product's name — the batch persists that label as it is.
    @Test
    func `Combination components persist with their combination name`() throws {
        let context = try makeContext()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let doses: [(entry: DoseEntry, substance: Substance?)] = [
            (DoseEntry(substance: unknown, amount: 500, timestamp: stamp, combinationName: "Co-codamol"), nil),
            (DoseEntry(substance: unknown + "2", amount: 30, timestamp: stamp, combinationName: "Co-codamol"), nil),
            (DoseEntry(substance: unknown, amount: 100, timestamp: stamp), nil),
        ]

        DoseLogService.shared.logBatch(doses, colors: [], in: context)

        let saved = try context.fetch(FetchDescriptor<DoseEntry>(sortBy: [SortDescriptor(\.amount)]))
        #expect(saved.map(\.amount) == [30, 100, 500])
        #expect(saved.map(\.combinationName) == ["Co-codamol", nil, "Co-codamol"])
        #expect(Set(saved.compactMap(\.session?.id)).count == 1)
    }

    @Test
    func `Checked batch commits assigned entry IDs and hook changes together`() throws {
        let context = try makeContext()
        let service = DoseLogService()
        defer { service.cancelPendingBookkeeping() }
        let one = entry(unknown)
        let two = entry(unknown, hoursFromNow: 1)

        let ids = try service.checkedLogBatch(
            [(one, nil), (two, nil)], colors: [], in: context, activatesLiveSession: false,
            beforeSave: { entries in
                #expect(entries.map(\.id) == [one.id, two.id])
                #expect(entries.allSatisfy { $0.session != nil })
                context.insert(DailyDoseItem(substance: unknown, amount: 10))
            },
        )

        #expect(ids == [one.id, two.id])
        let reader = ModelContext(context.container)
        #expect(try Set(reader.fetch(FetchDescriptor<DoseEntry>()).map(\.id)) == Set(ids))
        #expect(try reader.fetchCount(FetchDescriptor<DailyDoseItem>()) == 1)
        #expect(service.revision == 1)
        #expect(!context.hasChanges)
    }

    @Test
    func `Failed checked batch rolls back everything and can be retried once`() throws {
        enum FixtureError: Error { case stop }
        let context = try makeContext()
        let service = DoseLogService()
        defer { service.cancelPendingBookkeeping() }

        #expect(throws: FixtureError.self) {
            try service.checkedLogBatch(
                [(entry(unknown), nil)], colors: [], in: context, activatesLiveSession: false,
                beforeSave: { _ in
                    context.insert(DailyDoseItem(substance: unknown, amount: 10))
                    throw FixtureError.stop
                },
            )
        }

        #expect(try context.fetchCount(FetchDescriptor<DoseEntry>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<DailyDoseItem>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SubstanceColor>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Session>()) == 0)
        #expect(service.revision == 0)
        #expect(!context.hasChanges)

        let retry = entry(unknown)
        let ids = try service.checkedLogBatch([(retry, nil)], colors: [], in: context, activatesLiveSession: false)
        #expect(ids == [retry.id])
        #expect(try context.fetchCount(FetchDescriptor<DoseEntry>()) == 1)
        #expect(service.revision == 1)
    }

    @Test
    func `Checked batch leaves unrelated pending edits alone`() throws {
        let context = try makeContext()
        let service = DoseLogService()
        context.insert(DailyDoseItem(substance: unknown, amount: 10))

        #expect(throws: DoseLogService.CheckedCommitError.pendingChanges) {
            try service.checkedLogBatch([(entry(unknown), nil)], colors: [], in: context, activatesLiveSession: false)
        }

        #expect(context.hasChanges)
        #expect(try context.fetchCount(FetchDescriptor<DailyDoseItem>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<DoseEntry>()) == 0)
        #expect(service.revision == 0)
    }
}
