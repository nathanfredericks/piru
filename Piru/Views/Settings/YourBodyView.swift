import SwiftUI

struct YourBodyView: View {
    @State private var profile = UserProfileStore.shared
    @State private var vitals = HealthKitVitals.shared
    @AppStorage("showSessionVitals", store: UserDefaults(suiteName: AppIdentity.appGroup))
    private var showSessionVitals = false

    @State private var isConnecting = false
    /// Whether "Connect" would still surface a prompt. Once everything grantable is
    /// answered, the row is hidden — tapping it would only flash an empty sheet.
    /// Nil until the first async status check resolves, so the row doesn't flicker.
    @State private var connectWouldPrompt: Bool?

    var body: some View {
        Form {
            BodyWeightSection(profile: profile)
            metabolismSection
            if vitals.isAvailable {
                if connectWouldPrompt == true { connectSection }
                overlaySection
            } else {
                unavailableSection
            }
        }
        .navigationTitle("Your Body")
        .inlineNavigationTitle()
        .task { connectWouldPrompt = await vitals.connectWouldPrompt(for: .sessionVitals) }
    }

    // MARK: - Metabolism

    private var metabolismSection: some View {
        Section {
            GrapefruitRow(isOn: Binding(
                get: { profile.grapefruitLoggingEnabled },
                set: { profile.setGrapefruitLoggingEnabled($0) },
            ))
            AlcoholFlushRow(isOn: Binding(
                get: { profile.aldh2Deficient },
                set: { profile.setALDH2Deficient($0) },
            ))
        } header: {
            Text("Metabolism")
        }
    }

    // MARK: - Apple Health (access) — only while there's still something to grant

    private var connectSection: some View {
        Section {
            Button {
                Task { await connect() }
            } label: {
                HStack {
                    Label("Connect Apple Health", systemImage: "heart.text.square")
                    Spacer()
                    if isConnecting { ProgressView() }
                }
            }
            .disabled(isConnecting)
            .accessibilityValue(isConnecting ? Text("Connecting…") : Text(verbatim: ""))
        } header: {
            Text("Apple Health")
        } footer: {
            Text("Show heart rate, blood pressure, and workouts from Apple Health alongside your journal.")
        }
    }

    // MARK: - Heart data (the session overlay)

    private var overlaySection: some View {
        Section {
            Toggle(isOn: $showSessionVitals) {
                Label("Show heart data on sessions", systemImage: "waveform.path.ecg")
            }
            .onChange(of: showSessionVitals) { _, isOn in
                // Only prompt if there's actually something undetermined to grant;
                // otherwise just flip the overlay on (no empty-sheet flash).
                if isOn, !isConnecting, connectWouldPrompt == true { Task { await connect() } }
            }
        } header: {
            Text("Heart data")
        } footer: {
            Text("Shows your heart rate and blood pressure on each session's timeline. If something didn't connect (blood pressure especially, which iOS doesn't always prompt for), open **Settings ▸ Privacy & Security ▸ Health ▸ Piru** and turn it on there.")
        }
    }

    private var unavailableSection: some View {
        Section {
            Text("Apple Health isn't available on this device.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryLabel)
        }
    }

    // MARK: - Actions

    private func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        await vitals.requestAccess(.sessionVitals)
        showSessionVitals = true
        connectWouldPrompt = await vitals.connectWouldPrompt(for: .sessionVitals)
        isConnecting = false
    }
}

private struct BodyWeightSection: View {
    @Environment(\.locale) private var locale
    @AppStorage("bodyWeightDisplayUnit") private var preferredUnit = ""
    @FocusState private var editingWeight: Bool

    let profile: UserProfileStore
    @State private var draft: String?
    @State private var isReadingHealthWeight = false
    @State private var healthWeightResult: HealthKitBodyMass.SyncResult?

    private var unit: BodyWeightUnit {
        BodyWeightUnit(rawValue: preferredUnit) ?? BodyWeightUnit.defaultUnit(in: locale)
    }

    private var numberFormat: FloatingPointFormatStyle<Double> {
        .number.grouping(.never).precision(.fractionLength(0 ... 2)).locale(locale)
    }

    private var weightText: Binding<String> {
        Binding {
            draft ?? numberFormat.format(unit.value(fromKilograms: profile.effectiveWeightKg))
        } set: {
            draft = $0
        }
    }

    private var validDraftKg: Double? {
        draft.flatMap { unit.parseKilograms($0, locale: locale, range: UserProfileStore.weightRangeKg) }
    }

    var body: some View {
        Section {
            Picker("Weight Unit", selection: Binding(get: { unit }, set: { newUnit in
                let kilograms = validDraftKg
                preferredUnit = newUnit.rawValue
                draft = kilograms.map { numberFormat.format(newUnit.value(fromKilograms: $0)) }
            })) {
                ForEach(BodyWeightUnit.allCases, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }

            LabeledContent {
                HStack(spacing: 6) {
                    TextField("Body Weight", text: weightText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($editingWeight)
                        .onSubmit(save)
                        .accessibilityHint(Text(unit.label))
                    Text(unit.symbol)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            } label: {
                Text("Body Weight")
            }

            if HealthKitBodyMass.shared.isAvailable {
                Button {
                    Task { await readHealthWeight() }
                } label: {
                    HStack {
                        Text("Use Weight from Apple Health")
                        if isReadingHealthWeight { ProgressView() }
                    }
                }
                .disabled(isReadingHealthWeight || draft != nil)
            }

            if draft != nil {
                Button("Save Weight", action: save)
                    .disabled(validDraftKg == nil)
                Button("Cancel", role: .cancel, action: discardDraft)
            } else if profile.weightKg != nil {
                Button("Use Estimated Weight") {
                    profile.clearWeight()
                    healthWeightResult = nil
                    discardDraft()
                }
            }
        } header: {
            Text("Your weight")
        } footer: {
            if draft != nil, validDraftKg == nil {
                Text("Enter a weight between 20 and 300 kg or the equivalent in pounds.")
            } else if healthWeightResult == .noData {
                Text("No weight was available from Apple Health. Check your Health data and access settings.")
            } else {
                Text(weightSourceDescription)
            }
        }
    }

    private var weightSourceDescription: LocalizedStringResource {
        switch profile.weightSource {
        case .healthKit: "Weight from Apple Health. Piru uses it in modeled estimates."
        case .manual: "Weight entered manually. Piru uses it in modeled estimates."
        case .estimated: "Piru is using an estimated weight for its models."
        }
    }

    private func save() {
        guard let validDraftKg else { return }
        profile.setManualWeight(validDraftKg)
        healthWeightResult = nil
        discardDraft()
    }

    private func readHealthWeight() async {
        guard !isReadingHealthWeight else { return }
        isReadingHealthWeight = true
        defer { isReadingHealthWeight = false }
        if await HealthKitVitals.shared.connectWouldPrompt(for: .bodyWeight) {
            await HealthKitVitals.shared.requestAccess(.bodyWeight)
        }
        healthWeightResult = await HealthKitBodyMass.shared.syncLatest()
    }

    private func discardDraft() {
        draft = nil
        editingWeight = false
    }
}

nonisolated enum BodyWeightUnit: String, CaseIterable {
    case kilograms
    case pounds

    static func defaultUnit(in locale: Locale) -> Self {
        locale.measurementSystem == .us ? .pounds : .kilograms
    }

    var label: LocalizedStringResource {
        switch self {
        case .kilograms: "Kilograms"
        case .pounds: "Pounds"
        }
    }

    var symbol: String {
        unitMass.symbol
    }

    func value(fromKilograms kilograms: Double) -> Double {
        Measurement(value: kilograms, unit: UnitMass.kilograms).converted(to: unitMass).value
    }

    func kilograms(from value: Double) -> Double {
        Measurement(value: value, unit: unitMass).converted(to: .kilograms).value
    }

    func parseKilograms(_ text: String, locale: Locale, range: ClosedRange<Double>) -> Double? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.components(separatedBy: locale.decimalSeparator ?? ".")
        guard !text.isEmpty, parts.count <= 2, parts.allSatisfy({ $0.allSatisfy(\.isWholeNumber) }),
              let value = try? FloatingPointFormatStyle<Double>.number.locale(locale).parseStrategy.parse(text),
              value.isFinite else { return nil }
        let kilograms = kilograms(from: value)
        return range.contains(kilograms) ? kilograms : nil
    }

    private var unitMass: UnitMass {
        switch self {
        case .kilograms: .kilograms
        case .pounds: .pounds
        }
    }
}

// MARK: - Metabolism rows

private struct GrapefruitRow: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            CaptionedRowLabel(
                title: "Grapefruit dose logging",
                systemImage: "carrot",
                caption: Text("Adds a per-dose grapefruit toggle for substances whose breakdown grapefruit slows (CYP3A4), so the entry records it."),
            )
        }
    }
}

private struct AlcoholFlushRow: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            CaptionedRowLabel(
                title: "I get the alcohol flush",
                systemImage: "wineglass",
                caption: Text("Shows acetaldehyde buildup on alcohol entries. The ALDH2 variant slows its clearance, causing flushing."),
            )
        }
    }
}

#Preview {
    NavigationStack { YourBodyView() }
}
