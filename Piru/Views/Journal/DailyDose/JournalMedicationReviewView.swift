import SwiftData
import SwiftUI
import UIKit

struct JournalMedicationReviewView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.locale) private var locale
    @Query private var colors: [SubstanceColor]

    let day: Date
    let onSaved: () -> Void

    @State private var drafts: [JournalMedicationDraft]
    @State private var time: Date
    @State private var warnings: [InteractionResult] = []
    @State private var isSaving = false
    @State private var showsSaveError = false
    private let profileID = ProfileScope.currentID

    init(day: Date, scheduledMinutes: Int?, doses: [JournalMedicationDraft], onSaved: @escaping () -> Void) {
        self.day = day
        self.onSaved = onSaved
        _drafts = State(initialValue: doses)
        let now = Date.now
        let prefill = JournalDaySelection.prefill(on: day, now: now)
        if let scheduledMinutes, !Calendar.current.isJournalDayToday(day, now: now) {
            let range = JournalDaySelection.timeRange(on: day, now: now)
            let scheduled = AdherenceCalculator.slotDate(minutes: scheduledMinutes, on: day)
            _time = State(initialValue: range.contains(scheduled) ? scheduled : prefill)
        } else {
            _time = State(initialValue: prefill)
        }
    }

    var body: some View {
        Form {
            DatePicker("Taken at", selection: $time, in: JournalDaySelection.timeRange(on: day, now: .now))

            ForEach($drafts) { $draft in
                Section {
                    LabeledContent("Route") {
                        Text(draft.route.localizedName)
                    }
                    if draft.allowsAmountEditing {
                        Toggle("Unknown amount", isOn: $draft.unknownAmount)
                        if !draft.unknownAmount {
                            TextField("Amount", text: $draft.amount)
                                .decimalKeyboard()
                            TextField("Unit", text: $draft.unit)
                        }
                    } else if let planned = draft.configuration?.med {
                        LabeledContent("Amount", value: "\(planned.amount.doseFormatted) \(planned.unit)")
                    }
                } header: {
                    Text(draft.name)
                }
            }

            if !warnings.isEmpty {
                Section("Interaction Warning") {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                        NavigationLink {
                            InteractionTimelineView(
                                substanceA: warning.substanceA, substanceB: warning.substanceB,
                                severity: warning.severity, mechanism: warning.description,
                            )
                        } label: {
                            InteractionWarningRow(warning: warning)
                        }
                    }
                    Button("Log Anyway", role: .destructive) { save(acceptsWarnings: true) }
                        .disabled(!canSave)
                }
            }
        }
        .navigationTitle("Review Doses")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave || !warnings.isEmpty)
            }
        }
        .onChange(of: time) { warnings = [] }
        .onChange(of: drafts) { warnings = [] }
        .alert("Couldn’t Save Doses", isPresented: $showsSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your draft is still here. Review it and try again.")
        }
    }

    private var canSave: Bool {
        !isSaving && !drafts.isEmpty && drafts.allSatisfy { $0.isComplete(locale: locale) }
    }

    private func save(acceptsWarnings: Bool = false) {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let now = Date.now
            let today = Calendar.current.journalDay(for: now)
            guard profileID == ProfileScope.currentID, day <= today, time <= now,
                  JournalDaySelection.timeRange(on: day, now: now).contains(time)
            else {
                throw RoutineOccurrenceService.CorrectionError.occurrenceChanged
            }
            let isToday = day == today
            let entries = try drafts.map { try $0.entry(at: time, isToday: isToday, locale: locale, in: context) }
            if !acceptsWarnings {
                let cutoff = time.addingTimeInterval(-72 * 3_600)
                let end = time.addingTimeInterval(26 * 3_600)
                let recent = try context.fetch(FetchDescriptor<DoseEntry>(predicate: #Predicate {
                    $0.timestamp >= cutoff && $0.timestamp < end
                }))
                let active = InteractionChecker.activeEntries(from: recent, at: time)
                warnings = InteractionChecker.checkBatch(entries.map(\.substance), against: active, at: time).admitted(.notable)
                guard warnings.isEmpty else { return }
            }

            let batch = entries.map { entry in
                let substance = SubstanceLibrary.lookup(entry.substance).flatMap {
                    $0.name.caseInsensitiveCompare(entry.substance) == .orderedSame ? $0 : nil
                }
                return (entry: entry, substance: substance)
            }
            _ = try DoseLogService.shared.checkedLogBatch(
                batch, colors: colors, in: context, schedulesCheckIns: isToday,
                beforeSave: { inserted in
                    for (draft, entry) in zip(drafts, inserted) {
                        if let correction = draft.correction {
                            try RoutineOccurrenceService.stageTaken(correction, by: entry, in: context, now: now)
                        }
                    }
                },
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onSaved()
        } catch {
            showsSaveError = true
        }
    }
}

struct JournalMedicationDraft: Equatable, Identifiable {
    struct Configuration: Equatable {
        let id: PersistentIdentifier
        let med: DailyMedSnapshot
        let substanceUID: String?
        let saltForm: String?
        let releaseForm: String?
        let isomer: String?

        init(_ item: DailyDoseItem) {
            id = item.persistentModelID
            med = DailyMedSnapshot(item)
            substanceUID = item.substanceUID
            saltForm = item.saltForm
            releaseForm = item.releaseForm
            isomer = item.isomer
        }
    }

    let id: PersistentIdentifier
    let correction: RoutineOccurrenceService.Correction?
    let configuration: Configuration?
    let name: String
    let route: RouteOfAdministration
    private let substance: String
    private let substanceUID: String?
    private let slotMinutes: Int?

    var amount = ""
    var unit = ""
    var unknownAmount = false

    var allowsAmountEditing: Bool { configuration == nil || correction == nil }

    init(occurrence: RoutineOccurrence, item: DailyDoseItem?) {
        id = occurrence.persistentModelID
        correction = .init(occurrence)
        configuration = item.map(Configuration.init)
        name = configuration?.med.displayName ?? occurrence.substance
        route = occurrence.route
        substance = occurrence.substance
        substanceUID = occurrence.substanceUID
        slotMinutes = occurrence.slotMinutes
    }

    init(item: DailyDoseItem, locale: Locale) {
        id = item.persistentModelID
        correction = nil
        configuration = Configuration(item)
        name = DailyMedSnapshot(item).displayName
        route = item.route
        substance = item.substance
        substanceUID = item.substanceUID
        slotMinutes = nil
        amount = DecimalInput.editingText(item.amount, locale: locale)
        unit = item.unit
    }

    func isComplete(locale: Locale) -> Bool {
        if let configuration, !allowsAmountEditing {
            return configuration.med.amount.isFinite && configuration.med.amount > 0
        }
        if unknownAmount { return true }
        return DecimalInput.parse(amount, locale: locale).map { $0 > 0 } == true && !trimmedUnit.isEmpty
    }

    func entry(at time: Date, isToday: Bool, locale: Locale, in context: ModelContext) throws -> DoseEntry {
        guard isComplete(locale: locale) else { throw RoutineOccurrenceService.CorrectionError.invalidDose }
        if let configuration {
            let items = try context.fetch(FetchDescriptor<DailyDoseItem>())
            guard let item = items.first(where: { $0.persistentModelID == configuration.id && !$0.isDeleted }),
                  Configuration(item) == configuration, item.isAsNeeded == (correction == nil)
            else { throw RoutineOccurrenceService.CorrectionError.occurrenceChanged }
            if let correction {
                guard isToday, AdherenceCalculator.isDue(item, on: correction.day),
                      slotMinutes.map(item.reminderTimesMinutes.contains) ?? item.reminderTimesMinutes.isEmpty
                else { throw RoutineOccurrenceService.CorrectionError.occurrenceChanged }
            }
            let entry = DoseEntry.medication(item, at: time, slotMinutes: slotMinutes)
            if allowsAmountEditing {
                entry.amount = unknownAmount ? 0 : DecimalInput.parse(amount, locale: locale) ?? 0
                entry.unit = trimmedUnit
                entry.isUnknownDose = unknownAmount
            }
            return entry
        }

        return DoseEntry(
            substance: substance, amount: DecimalInput.parse(amount, locale: locale) ?? 0,
            unit: trimmedUnit, route: route, substanceUID: substanceUID,
            timestamp: time, medSlotMinutes: slotMinutes, isUnknownDose: unknownAmount,
        )
    }

    private var trimmedUnit: String { unit.trimmingCharacters(in: .whitespacesAndNewlines) }
}
