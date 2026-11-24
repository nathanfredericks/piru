import SwiftData
import SwiftUI

enum JournalMedicationSheet: Hashable, Identifiable {
    case scheduled(day: Date, minutes: Int?)
    case asNeeded(day: Date)

    var id: Self { self }
}

struct JournalMedicationGroup: Identifiable {
    let minutes: Int?
    let occurrences: [RoutineOccurrence]

    var id: Int? { minutes }

    static func groups(from occurrences: [RoutineOccurrence], boundaryHour: Int) -> [Self] {
        Dictionary(grouping: occurrences, by: \.slotMinutes)
            .map { minutes, rows in
                Self(minutes: minutes, occurrences: rows.sorted {
                    $0.substance.localizedStandardCompare($1.substance) == .orderedAscending
                })
            }
            .sorted { order($0.minutes, boundaryHour: boundaryHour) < order($1.minutes, boundaryHour: boundaryHour) }
    }

    private static func order(_ minutes: Int?, boundaryHour: Int) -> Int {
        minutes.map { Calendar.journalMinutes(ofSlot: $0, boundaryHour: boundaryHour) } ?? .max
    }

    static func scheduledItem(for occurrence: RoutineOccurrence, in items: [DailyDoseItem]) -> DailyDoseItem? {
        items.first { item in
            !item.isAsNeeded && item.route == occurrence.route
                && MedSchedule.identityMatches(
                    keyA: item.substanceUID, nameA: item.substance,
                    keyB: occurrence.substanceUID, nameB: occurrence.substance,
                )
                && AdherenceCalculator.isDue(item, on: occurrence.dueDay)
                && (occurrence.slotMinutes.map(item.reminderTimesMinutes.contains) ?? item.reminderTimesMinutes.isEmpty)
        }
    }

    static func title(for minutes: Int?) -> String {
        guard let minutes else { return String(localized: "Anytime") }
        let time = Date(timeIntervalSince1970: TimeInterval(minutes * 60))
        var format = Date.FormatStyle(date: .omitted, time: .shortened)
        format.timeZone = .gmt
        return time.formatted(format)
    }
}

struct JournalMedicationGroupLabel: View {
    let group: JournalMedicationGroup
    let items: [DailyDoseItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(JournalMedicationGroup.title(for: group.minutes), systemImage: group.minutes == nil ? "pills" : "clock")
            ForEach(group.occurrences) { occurrence in
                let name = JournalMedicationGroup.scheduledItem(for: occurrence, in: items)
                    .map { DailyMedSnapshot($0).displayName } ?? occurrence.substance
                LabeledContent(name, value: String(localized: occurrence.state.journalLabel))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct JournalMedicationSheetView: View {
    @Environment(\.dismiss) private var dismiss

    let selection: JournalMedicationSheet

    var body: some View {
        NavigationStack {
            Group {
                switch selection {
                case let .scheduled(day, minutes):
                    JournalScheduledGroupView(day: day, minutes: minutes, onSaved: { dismiss() })
                case let .asNeeded(day):
                    JournalAsNeededView(day: day, onSaved: { dismiss() })
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct JournalScheduledGroupView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var occurrences: [RoutineOccurrence]
    @Query(sort: \DailyDoseItem.sortOrder) private var items: [DailyDoseItem]

    let day: Date
    let minutes: Int?
    let onSaved: () -> Void

    @State private var removal: JournalDoseRemoval?
    @State private var showsError = false

    init(day: Date, minutes: Int?, onSaved: @escaping () -> Void) {
        self.day = day
        self.minutes = minutes
        self.onSaved = onSaved
        _occurrences = Query(
            filter: #Predicate<RoutineOccurrence> { $0.dueDay == day && $0.slotMinutes == minutes },
            sort: \RoutineOccurrence.substance,
        )
    }

    var body: some View {
        List {
            Section {
                ForEach(occurrences) { occurrence in
                    occurrenceRow(occurrence)
                }
            } header: {
                Text(day.formatted(date: .complete, time: .omitted))
            }

            let outstanding = occurrences.filter { $0.state == .pending || $0.state == .missed }
            if outstanding.count > 1 {
                Section {
                    NavigationLink("Mark All Outstanding as Taken") {
                        review(outstanding)
                    }
                }
            }
        }
        .navigationTitle(JournalMedicationGroup.title(for: minutes))
        .confirmationDialog(
            "Remove Logged Dose?",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            titleVisibility: .visible, presenting: removal,
        ) { target in
            Button("Remove Logged Dose", role: .destructive) { removeDose(target) }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(verbatim: target.confirmationDetails)
        }
        .alert("Couldn’t Update Medication", isPresented: $showsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The record may have changed. Review the current entry and try again.")
        }
    }

    private func occurrenceRow(_ row: RoutineOccurrence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                Text(row.state.journalLabel)
            } label: {
                Text(item(for: row).map { DailyMedSnapshot($0).displayName } ?? row.substance)
            }
            .accessibilityElement(children: .combine)

            if row.state == .logged {
                Button("Remove Logged Dose", role: .destructive) { prepareRemoval(row) }
                    .buttonStyle(.borderless)
            } else {
                NavigationLink("Mark Taken") { review([row]) }
                if row.state == .skipped {
                    Button("Undo Skip") { setSkipped(false, row: row) }
                        .buttonStyle(.borderless)
                } else {
                    Button("Mark Skipped") { setSkipped(true, row: row) }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private func review(_ rows: [RoutineOccurrence]) -> some View {
        JournalMedicationReviewView(
            day: day, scheduledMinutes: minutes,
            doses: rows.map { JournalMedicationDraft(occurrence: $0, item: item(for: $0)) },
            onSaved: onSaved,
        )
    }

    private func item(for occurrence: RoutineOccurrence) -> DailyDoseItem? {
        guard Calendar.current.isJournalDayToday(day) else { return nil }
        return JournalMedicationGroup.scheduledItem(for: occurrence, in: items)
    }

    private func setSkipped(_ skipped: Bool, row: RoutineOccurrence) {
        do {
            try RoutineOccurrenceService.setSkipped(skipped, for: .init(row), in: modelContext)
        } catch {
            showsError = true
        }
    }

    private func prepareRemoval(_ row: RoutineOccurrence) {
        do {
            let correction = RoutineOccurrenceService.Correction(row)
            let entry = try RoutineOccurrenceService.linkedEntry(for: correction, in: modelContext)
            removal = JournalDoseRemoval(correction: correction, entry: entry)
        } catch {
            showsError = true
        }
    }

    private func removeDose(_ target: JournalDoseRemoval) {
        do {
            try SessionEditingService.shared.deleteOccurrenceDose(target.correction, in: modelContext, confirming: target.matches)
        } catch {
            showsError = true
        }
    }
}

private struct JournalAsNeededView: View {
    @Environment(\.locale) private var locale
    @Query(
        filter: #Predicate<DailyDoseItem> { $0.isAsNeeded },
        sort: \DailyDoseItem.sortOrder,
    ) private var items: [DailyDoseItem]

    let day: Date
    let onSaved: () -> Void

    var body: some View {
        List(items) { item in
            NavigationLink {
                JournalMedicationReviewView(
                    day: day, scheduledMinutes: nil,
                    doses: [JournalMedicationDraft(item: item, locale: locale)], onSaved: onSaved,
                )
            } label: {
                LabeledContent(DailyMedSnapshot(item).displayName, value: "\(item.amount.doseFormatted) \(item.unit)")
            }
        }
        .navigationTitle("As needed")
    }
}

private struct JournalDoseRemoval {
    let correction: RoutineOccurrenceService.Correction
    let confirmationDetails: String
    private let title: String
    private let amount: Double
    private let unit: String
    private let unknownAmount: Bool
    private let timestamp: Date
    private let timeZoneIdentifier: String?
    private let route: RouteOfAdministration

    init(correction: RoutineOccurrenceService.Correction, entry: DoseEntry) {
        self.correction = correction
        title = DoseTitle.resolve(for: entry)
        amount = entry.amount
        unit = entry.unit
        unknownAmount = entry.isUnknownDose
        timestamp = entry.timestamp
        timeZoneIdentifier = entry.timeZoneIdentifier
        route = entry.route
        var format = Date.FormatStyle(date: .abbreviated, time: .shortened)
        format.timeZone = Calendar.current.loggedIn(entry.timeZoneIdentifier).timeZone
        let shownAmount = unknownAmount ? String(localized: "Unknown amount") : "\(entry.amountDisplay) \(unit)"
        confirmationDetails = [title, shownAmount, String(localized: route.localizedName), timestamp.formatted(format)]
            .joined(separator: "\n")
    }

    func matches(_ entry: DoseEntry) -> Bool {
        entry.id == correction.entryID && entry.timestamp == timestamp && entry.route == route
            && entry.timeZoneIdentifier == timeZoneIdentifier
            && DoseTitle.resolve(for: entry) == title && entry.amount == amount && entry.unit == unit
            && entry.isUnknownDose == unknownAmount
    }
}

extension RoutineOccurrence.State {
    var journalLabel: LocalizedStringResource {
        switch self {
        case .pending, .missed: "Not Logged"
        case .logged: "Taken"
        case .skipped: "Skipped"
        }
    }
}
