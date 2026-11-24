import SwiftData
import SwiftUI

struct TodayJournalView: View {
    @Environment(\.appNavigator) private var navigator
    @Environment(\.modelContext) private var modelContext
    @Environment(\.opensRecordsBesideList) private var opensRecordsBesideList
    @AppStorage(Calendar.dayBoundaryHourKey, store: UserDefaults(suiteName: AppIdentity.appGroup)) private var boundaryHour = 4

    @Binding var searchText: String
    @State private var browsedDate: Date?
    @State private var catalogReady = false

    init(searchText: Binding<String> = .constant("")) {
        _searchText = searchText
    }

    var body: some View {
        TimelineView(.everyMinute) { clock in
            let calendar = Calendar.current
            let now = clock.date
            let today = calendar.journalDay(for: now, boundaryHour: boundaryHour)
            let day = min(browsedDate.map { calendar.startOfDay(for: $0) } ?? today, today)

            Group {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    JournalDayContent(
                        day: day, today: today, boundaryHour: boundaryHour, catalogReady: catalogReady,
                        date: Binding(
                            get: { day },
                            set: { browsedDate = calendar.startOfDay(for: $0) == today ? nil : $0 },
                        ),
                    )
                } else {
                    EntryListView(searchText: $searchText, isSearchSurface: true)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if day != today {
                        Button("Today") { browsedDate = nil }
                    }
                    Menu("History", systemImage: "clock.arrow.circlepath") {
                        Button("Days", systemImage: "calendar") {
                            navigator.openRecord(.journalDays, besideList: opensRecordsBesideList)
                        }
                        Button("Timeline", systemImage: "chart.xyaxis.line") {
                            navigator.openRecord(.timeline, besideList: opensRecordsBesideList)
                        }
                    }
                    Button {
                        let time = day == today ? nil : JournalDaySelection.prefill(on: day, now: .now, boundaryHour: boundaryHour)
                        navigator.present(.quickLog(routine: nil, prefillDate: time))
                    } label: {
                        Label("Log Dose", systemImage: "plus")
                    }
                }
            }
            .task(id: today) {
                RoutineOccurrenceService.reconcile(in: modelContext, now: .now)
            }
        }
        .navigationTitle("Journal")
        .journalProfileSubtitle(enabled: true)
        .task {
            await SubstanceStore.shared.ensureAllLoaded()
            catalogReady = true
        }
    }
}

nonisolated enum JournalDaySelection {
    static func timeRange(
        on day: Date, now: Date, calendar: Calendar = .current, boundaryHour: Int = Calendar.sessionDayBoundaryHour,
    ) -> ClosedRange<Date> {
        let start = calendar.journalDayStart(of: day, boundaryHour: boundaryHour)
        let next = calendar.journalDayStart(of: calendar.journalDay(after: day), boundaryHour: boundaryHour)
        return start ... max(start, min(now, next.addingTimeInterval(-1)))
    }

    static func prefill(
        on day: Date, now: Date, calendar: Calendar = .current, boundaryHour: Int = Calendar.sessionDayBoundaryHour,
    ) -> Date {
        let range = timeRange(on: day, now: now, calendar: calendar, boundaryHour: boundaryHour)
        if range.contains(now) { return now }
        let clock = calendar.dateComponents([.hour, .minute], from: now)
        let minutes = (clock.hour ?? 0) * 60 + (clock.minute ?? 0)
        let proposed = calendar.date(ofSlot: minutes, inJournalDay: day, boundaryHour: boundaryHour)
        return max(range.lowerBound, min(proposed, range.upperBound))
    }
}

private struct JournalDayContent: View {
    @Environment(\.appNavigator) private var navigator
    @Environment(\.opensRecordsBesideList) private var opensRecordsBesideList
    @Query private var entries: [DoseEntry]
    @Query private var occurrences: [RoutineOccurrence]
    @Query(sort: \DailyDoseItem.sortOrder) private var items: [DailyDoseItem]

    let day: Date
    let today: Date
    let boundaryHour: Int
    let catalogReady: Bool
    @Binding var date: Date
    @State private var medicationSheet: JournalMedicationSheet?

    init(day: Date, today: Date, boundaryHour: Int, catalogReady: Bool, date: Binding<Date>) {
        self.day = day
        self.today = today
        self.boundaryHour = boundaryHour
        self.catalogReady = catalogReady
        _date = date
        let window = Calendar.current.doseFetchWindow(forJournalDay: day, boundaryHour: boundaryHour)
        let start = window.start, end = window.end
        _entries = Query(
            filter: #Predicate<DoseEntry> { $0.timestamp >= start && $0.timestamp < end },
            sort: \DoseEntry.timestamp, order: .reverse,
        )
        _occurrences = Query(filter: #Predicate<RoutineOccurrence> { $0.dueDay == day })
    }

    var body: some View {
        List {
            Section {
                DatePicker(day == today ? "Today" : "Date", selection: $date, in: ...today, displayedComponents: .date)
            }

            let groups = JournalMedicationGroup.groups(from: occurrences, boundaryHour: boundaryHour)
            let hasAsNeeded = items.contains(where: \.isAsNeeded)
            if !groups.isEmpty || hasAsNeeded {
                Section("Medications") {
                    ForEach(groups) { group in
                        Button {
                            medicationSheet = .scheduled(day: day, minutes: group.minutes)
                        } label: {
                            JournalMedicationGroupLabel(group: group, items: day == today && catalogReady ? items : [])
                        }
                    }
                    if hasAsNeeded {
                        Button {
                            medicationSheet = .asNeeded(day: day)
                        } label: {
                            Label("As needed", systemImage: "pills")
                        }
                    }
                }
                .disabled(!catalogReady)
            }

            Section("Recorded Entries") {
                let dayEntries = entries.filter { $0.journalDay(boundaryHour: boundaryHour) == day }
                if !catalogReady {
                    ProgressView()
                } else if dayEntries.isEmpty {
                    Text("No entries for this day.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dayEntries) { entry in
                        Button {
                            navigator.openRecord(.entry(timestamp: entry.timestamp, id: entry.id), besideList: opensRecordsBesideList)
                        } label: {
                            JournalRecordedDoseLabel(entry: entry)
                        }
                    }
                }
            }
        }
        .sheet(item: $medicationSheet) { selection in
            JournalMedicationSheetView(selection: selection)
        }
    }
}

struct JournalRecordedDoseLabel: View {
    let entry: DoseEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(DoseTitle.resolve(for: entry))
                .foregroundStyle(.primary)
            if entry.isUnknownDose {
                Text("Unknown amount")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(entry.amountDisplay) \(entry.unit)")
                    .foregroundStyle(.secondary)
            }
            Text(entry.route.localizedName)
                .foregroundStyle(.secondary)
            Text(entry.timestamp, format: timeFormat)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var timeFormat: Date.FormatStyle {
        var format = Date.FormatStyle(date: .omitted, time: .shortened)
        format.timeZone = Calendar.current.loggedIn(entry.timeZoneIdentifier).timeZone
        return format
    }
}
