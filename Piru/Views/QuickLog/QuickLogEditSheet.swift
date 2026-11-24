import SwiftData
import SwiftUI

struct QuickLogEditSheet: View {
    @Query(sort: \DailyDoseItem.sortOrder) private var items: [DailyDoseItem]
    @Query(sort: [SortDescriptor(\FavoriteSubstance.sortOrder), SortDescriptor(\FavoriteSubstance.createdAt, order: .reverse)]) private var favorites: [FavoriteSubstance]

    @Environment(\.modelContext) private var modelContext
    @State private var customStore = CustomSubstanceStore.shared
    @AppStorage(QuickLogManager.fixedOrderDefaultsKey) private var quickLogFixedOrder = false
    /// Saved offsets for the When menu.
    @AppStorage(DoseTimeDefaults.choicesKey, store: UserDefaults(suiteName: DoseTimeDefaults.suite))
    private var doseTimeChoicesRaw = DoseTimeDefaults.defaultRaw

    @State private var doseTimeChoices: [Int] = []

    var body: some View {
        List {
            medsSection
            favoritesSection
            Section {
                NavigationLink("Drinks") { QuickLogDrinkPresets(substanceName: "Alcohol") }
            }
            doseTimesSection
            orderSection
        }
        .navigationTitle("Edit Quick Log")
        .toolbar { EditButton() }
        .onAppear { doseTimeChoices = DoseTimeDefaults.parse(doseTimeChoicesRaw) }
        .onChange(of: doseTimeChoices) { _, new in
            doseTimeChoicesRaw = DoseTimeDefaults.format(new)
        }
    }

    // MARK: Meds

    private var medsSection: some View {
        Section {
            ForEach(items) { item in
                medRow(item)
            }
            .onMove(perform: moveMeds)
            .onDelete(perform: deleteMeds)

        } header: {
            Text("My Meds")
                .textCase(nil)
        }
    }

    /// Name + dose and reminder times — plain rows, matching the favorites
    /// section below. Editing schedules lives in the My Meds hub.
    private func medRow(_ item: DailyDoseItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(item.productName ?? customStore.displayName(for: item.substance))
            HStack(spacing: Spacing.xs) {
                Text(verbatim: "\(item.amount.doseFormatted) \(item.unit)")
                if let first = item.reminderTimesMinutes.sorted().first,
                   let time = Calendar.current.date(
                       bySettingHour: first / 60, minute: first % 60, second: 0, of: .now,
                   ) {
                    Text(time, style: .time)
                    if item.reminderTimesMinutes.count > 1 {
                        Text(verbatim: "+\(item.reminderTimesMinutes.count - 1)")
                    }
                    if item.remind {
                        Image(systemName: "bell.fill")
                            .font(.caption2)
                            .accessibilityLabel("Reminder on")
                    }
                }
            }
            .captionSecondary()
            .accessibilityElement(children: .combine)
        }
    }

    // Every mutation below saves explicitly — this sheet can be torn down the
    // moment the handler returns (Done, swipe), and an edit still sitting in
    // the context when the container is released is silently lost.

    private func moveMeds(from source: IndexSet, to destination: Int) {
        var ordered = items
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, item) in ordered.enumerated() {
            item.sortOrder = index
        }
        try? modelContext.save()
    }

    private func deleteMeds(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(items[index])
        }
        try? modelContext.save()
        DoseNotificationManager.syncMedReminders(in: modelContext)
    }

    // MARK: Favorites

    private var favoritesSection: some View {
        Section {
            ForEach(favorites) { favorite in
                Text(customStore.displayName(for: favorite.substance))
            }
            .onMove(perform: moveFavorites)
            .onDelete(perform: deleteFavorites)

            NavigationLink {
                AddFavoriteView()
            } label: {
                Label("Add Favorite…", systemImage: "star")
            }
        } header: {
            Text("Favorites")
                .textCase(nil)
        }
    }

    private func moveFavorites(from source: IndexSet, to destination: Int) {
        var ordered = favorites
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, favorite) in ordered.enumerated() {
            favorite.sortOrder = index
        }
        try? modelContext.save()
        PhoneSyncCoordinator.shared.pushManifest()
    }

    private func deleteFavorites(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(favorites[index])
        }
        try? modelContext.save()
        PhoneSyncCoordinator.shared.pushManifest()
    }

    // MARK: Order

    private var orderSection: some View {
        Section {
            Toggle(isOn: $quickLogFixedOrder) {
                Label("Keep Order", systemImage: "pin")
            }
        } footer: {
            Text("Keep substances in a fixed order. When off, recording an entry moves its substance to the front.")
        }
    }

    // MARK: Dose times

    private var doseTimesSection: some View {
        Section {
            ForEach(doseTimeChoices, id: \.self) { minutes in
                Label(TrayTime.offsetLabel(minutes: minutes), systemImage: "clock.arrow.circlepath")
            }
            .onDelete(perform: deleteDoseTimes)
            .onMove(perform: moveDoseTimes)

            if doseTimeChoices.count < DoseTimeDefaults.maxCount {
                NavigationLink {
                    DoseTimePresetForm(existing: doseTimeChoices) { minutes in
                        doseTimeChoices.append(minutes)
                    }
                } label: {
                    Label("Add Preset…", systemImage: "plus.circle")
                }
            }
        } header: {
            Text("Entry Times")
                .textCase(nil)
        } footer: {
            Text("The quick time options in the “Now” menu when recording an entry.")
        }
    }

    private func deleteDoseTimes(at offsets: IndexSet) {
        // Keep at least one preset so the "Now" menu never empties out.
        guard doseTimeChoices.count - offsets.count >= 1 else { return }
        doseTimeChoices.remove(inRangeOffsets: offsets)
    }

    private func moveDoseTimes(from source: IndexSet, to destination: Int) {
        doseTimeChoices.move(fromOffsets: source, toOffset: destination)
    }
}

/// A substance picker pushed from the Edit sheet's Favorites section: choosing a
/// substance stars it (creates a ``FavoriteSubstance``) and pops back.
private struct AddFavoriteView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FavoriteSubstance.sortOrder) private var favorites: [FavoriteSubstance]
    @State private var query = ""

    private var favoriteNames: Set<String> {
        Set(favorites.map { $0.substance.lowercased() })
    }

    var body: some View {
        List {
            Section {
                SubstanceSearchField(text: $query, favoriteNames: favoriteNames) { substance, _ in
                    add(substance)
                }
            } footer: {
                Text("Star a substance to keep it in your quick-log favorites.")
            }
        }
        .navigationTitle("Add Favorite")
        .inlineNavigationTitle()
    }

    private func add(_ substance: Substance) {
        guard !favoriteNames.contains(substance.name.lowercased()) else {
            dismiss()
            return
        }
        FavoriteService.add(substance: substance.name, substanceUID: substance.substanceUID, in: modelContext)
        dismiss()
    }
}

struct QuickLogDrinkPresets: View {
    let substanceName: String

    @Environment(\.modelContext) private var modelContext
    @Query private var presets: [CustomDrinkPreset]

    init(substanceName: String) {
        self.substanceName = substanceName
        let name = substanceName.lowercased()
        _presets = Query(
            filter: #Predicate { $0.substanceName == name },
            sort: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)],
        )
    }

    private var isConcentration: Bool {
        SubstanceLibrary.lookup(substanceName)?.byVolumeDosing?.isMassPerVolume == true
    }

    var body: some View {
        List {
            ForEach(presets) { preset in
                NavigationLink {
                    DrinkPresetForm(preset: preset, substanceName: substanceName)
                } label: {
                    VStack(alignment: .leading) {
                        Text(verbatim: preset.name)
                        Text(verbatim: preset.detailLabel).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .onMove { source, destination in
                var ordered = presets
                ordered.move(fromOffsets: source, toOffset: destination)
                for (index, preset) in ordered.enumerated() { preset.sortOrder = Double(index) }
                try? modelContext.save()
            }
            .onDelete { offsets in
                for index in offsets { modelContext.delete(presets[index]) }
                try? modelContext.save()
            }
            NavigationLink {
                DrinkPresetForm(preset: nil, substanceName: substanceName)
            } label: {
                Text(isConcentration ? "Add Concentration" : "New Drink…")
            }
        }
        .navigationTitle(isConcentration ? Text("Concentrations") : Text("Drinks"))
        .toolbar { EditButton() }
    }
}
