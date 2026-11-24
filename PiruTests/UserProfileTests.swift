import Foundation
import SwiftData
import Testing
@testable import Piru

@Suite("UserProfileStore", .serialized)
@MainActor
struct UserProfileStoreTests {
    /// A throwaway in-memory container using the full app schema (the pattern the other SwiftData
    /// suites use). Single-entity in-memory containers proved flaky under the parallel runner.
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(PiruSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none),
        )
    }

    /// A store bound to a throwaway in-memory container, with no legacy migration.
    private func makeStore() throws -> UserProfileStore {
        let store = UserProfileStore()
        try store.configure(container: makeContainer(), legacyPrefsDBURL: nil)
        return store
    }

    @Test(arguments: ["casual", "harm-reduction", "pharma-nerd", "future-tier"])
    func `Legacy disclosure values round-trip through sync and native export`(wireValue: String) throws {
        let source = try makeContainer()
        let target = try makeContainer()
        let sourceRecord = UserProfileRecord(
            disclosureTierRaw: wireValue, bodyWeightKg: 73, weightSourceRaw: "manual",
            grapefruitLoggingEnabled: true, aldh2Deficient: true,
        )
        source.mainContext.insert(sourceRecord)
        try source.mainContext.save()

        let key = SyncRecordKey(kind: "userProfile", id: SyncProjection.singletonID)
        let profileID = UUID()
        let projectedFields = try SyncProjection.fields(for: key, in: source.mainContext, profileID: profileID)
        let fields = try #require(projectedFields)
        let encodedWireValue = try SyncJSON.encode(wireValue)
        #expect(fields["disclosureTierRaw"] == encodedWireValue)
        try SyncProjection.apply(key, fields: fields, in: target.mainContext, profileID: profileID)
        try target.mainContext.save()

        let store = UserProfileStore()
        store.configure(container: target, legacyPrefsDBURL: nil)
        #expect(store.weightKg == 73)
        #expect(store.weightSource == .manual)
        #expect(store.grapefruitLoggingEnabled)
        #expect(store.aldh2Deficient)

        store.setManualWeight(75)
        let record = try #require(target.mainContext.fetch(FetchDescriptor<UserProfileRecord>()).first)
        let data = try JSONEncoder().encode(PiruProfileData(record))
        let decoded = try JSONDecoder().decode(PiruProfileData.self, from: data)
        let restored = UserProfileRecord()
        decoded.apply(to: restored)
        #expect(restored.disclosureTierRaw == wireValue)
        #expect(restored.bodyWeightKg == 75)
        #expect(restored.grapefruitLoggingEnabled)
        #expect(restored.aldh2Deficient)
    }

    @Test
    func `A legacy detail preference does not block restoring physiology`() throws {
        let target = try makeContainer()
        let existing = UserProfileRecord(disclosureTierRaw: "pharma-nerd")
        target.mainContext.insert(existing)
        try target.mainContext.save()

        let bytes = Data("""
        {
          "piruExportVersion": 4,
          "profile": {
            "disclosureTier": "casual",
            "bodyWeightKg": 73,
            "weightSource": "manual",
            "grapefruitLoggingEnabled": true,
            "aldh2Deficient": true
          }
        }
        """.utf8)
        let file = try JSONDecoder().decode(PiruFile.self, from: bytes)
        try DataExportImport.importNativeRecords(file, context: target.mainContext)
        try target.mainContext.save()

        #expect(existing.disclosureTierRaw == "pharma-nerd")
        #expect(existing.bodyWeightKg == 73)
        #expect(existing.weightSourceRaw == "manual")
        #expect(existing.grapefruitLoggingEnabled)
        #expect(existing.aldh2Deficient)
    }

    @Test
    func `New physiology records retain the historical sync default`() throws {
        let container = try makeContainer()
        let store = UserProfileStore()
        store.configure(container: container, legacyPrefsDBURL: nil)
        store.setManualWeight(75)
        let record = try #require(container.mainContext.fetch(FetchDescriptor<UserProfileRecord>()).first)
        #expect(record.disclosureTierRaw == "harm-reduction")
    }

    // MARK: - Body weight

    @Test
    func `Unset weight falls back to default and is estimated`() throws {
        let store = try makeStore()
        #expect(store.weightKg == nil)
        #expect(store.isWeightEstimated)
        #expect(store.weightSource == .estimated)
        #expect(store.effectiveWeightKg == UserProfileStore.defaultWeightKg)
    }

    @Test
    func `Manual weight is stored and no longer estimated`() throws {
        let store = try makeStore()
        store.setManualWeight(72)
        #expect(store.weightKg == 72)
        #expect(!store.isWeightEstimated)
        #expect(store.weightSource == .manual)
        #expect(store.effectiveWeightKg == 72)
    }

    @Test
    func `HealthKit weight records its source`() throws {
        let store = try makeStore()
        store.setHealthKitWeight(64.5)
        #expect(store.weightKg == 64.5)
        #expect(store.weightSource == .healthKit)
        #expect(!store.isWeightEstimated)
    }

    @Test
    func `Out-of-range and non-finite weights are rejected`() throws {
        let store = try makeStore()
        store.setManualWeight(5)
        store.setManualWeight(500)
        store.setManualWeight(.nan)
        store.setManualWeight(.infinity)
        #expect(store.weightKg == nil)
        #expect(store.isWeightEstimated)
    }

    @Test
    func `Range bounds are inclusive`() throws {
        let store = try makeStore()
        store.setManualWeight(20)
        #expect(store.weightKg == 20)
        store.setManualWeight(300)
        #expect(store.weightKg == 300)
    }

    @Test
    func `Clearing weight reverts to estimated default`() throws {
        let store = try makeStore()
        store.setManualWeight(80)
        store.clearWeight()
        #expect(store.weightKg == nil)
        #expect(store.isWeightEstimated)
        #expect(store.weightSource == .estimated)
        #expect(store.effectiveWeightKg == UserProfileStore.defaultWeightKg)
    }

    @Test
    func `Weight persists across stores on the same container`() throws {
        let container = try makeContainer()
        let first = UserProfileStore()
        first.configure(container: container, legacyPrefsDBURL: nil)
        first.setHealthKitWeight(70)

        let second = UserProfileStore()
        second.configure(container: container, legacyPrefsDBURL: nil)
        #expect(second.weightKg == 70)
        #expect(second.weightSource == .healthKit)
    }

    // MARK: - Metabolic context flags (Stage 4c)

    @Test
    func `Metabolic context flags default off`() throws {
        let store = try makeStore()
        #expect(!store.grapefruitLoggingEnabled)
    }

    @Test
    func `Grapefruit flag persists across stores`() throws {
        let container = try makeContainer()
        let first = UserProfileStore()
        first.configure(container: container, legacyPrefsDBURL: nil)
        first.setGrapefruitLoggingEnabled(true)

        let second = UserProfileStore()
        second.configure(container: container, legacyPrefsDBURL: nil)
        #expect(second.grapefruitLoggingEnabled)
    }

    // MARK: - ALDH2 phenotype (Stage 5)

    @Test
    func `ALDH2 flag defaults off`() throws {
        let store = try makeStore()
        #expect(!store.aldh2Deficient)
    }

    @Test
    func `ALDH2 flag persists across stores and is independent of other flags`() throws {
        let container = try makeContainer()
        let first = UserProfileStore()
        first.configure(container: container, legacyPrefsDBURL: nil)
        first.setALDH2Deficient(true)

        let second = UserProfileStore()
        second.configure(container: container, legacyPrefsDBURL: nil)
        #expect(second.aldh2Deficient)
        #expect(!second.grapefruitLoggingEnabled)
    }

    @Test
    func `Setting same ALDH2 value is a no-op and clears cleanly`() throws {
        let store = try makeStore()
        store.setALDH2Deficient(true)
        store.setALDH2Deficient(true)
        #expect(store.aldh2Deficient)
        store.setALDH2Deficient(false)
        #expect(!store.aldh2Deficient)
    }
}

@Suite("AcetaldehydeCard load")
struct AcetaldehydeLoadTests {
    @Test
    func `Load band scales with standard drinks`() {
        // 14 g ≈ 1 standard drink → elevated; ~3 drinks → high; heavy → very high.
        #expect(AcetaldehydeCard.Load(standardDrinks: 1) == .elevated)
        #expect(AcetaldehydeCard.Load(standardDrinks: 2) == .high)
        #expect(AcetaldehydeCard.Load(standardDrinks: 5) == .veryHigh)
    }
}

@Suite("Source priority")
struct SourcePriorityTests {
    @Test
    @MainActor
    func `Source states cover every bundled source`() {
        let states = SubstanceStore.shared.sourceStates()
        #expect(!states.isEmpty)
        // All states have non-empty slugs and display names
        for state in states {
            #expect(!state.slug.isEmpty)
            #expect(!state.displayName.isEmpty)
        }
    }

    @Test
    @MainActor
    func `Reordering changes enabledSourceOrder and clears resolved cache`() throws {
        let (store, tempDir) = try makeIsolatedSubstanceStore()
        defer { tearDownIsolatedSubstanceStore(store, tempDir: tempDir) }

        let originalOrder = store.enabledSourceOrder
        guard originalOrder.count >= 2 else { return }
        let reversed = originalOrder.reversed()
        store.setSourcePriority(orderedSlugs: Array(reversed))
        #expect(store.enabledSourceOrder.first == reversed.first)
    }

    @Test
    @MainActor
    func `Disabling a source removes it from enabledSourceOrder`() throws {
        let (store, tempDir) = try makeIsolatedSubstanceStore()
        defer { tearDownIsolatedSubstanceStore(store, tempDir: tempDir) }

        let original = store.enabledSourceOrder
        guard let toDisable = original.last else { return }

        store.setSource(toDisable, enabled: false)
        #expect(!store.enabledSourceOrder.contains(toDisable))
    }
}
