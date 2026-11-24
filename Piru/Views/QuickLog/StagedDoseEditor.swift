import SwiftData
import SwiftUI

struct StagedDoseEditor: View {
    @Binding var item: StagedDose
    let time: TrayTime
    let lastDose: CardPKBadge?
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var model = StagedDoseEditorModel()
    @State private var profileStore = UserProfileStore.shared
    @State private var solutionByVolume = false
    @FocusState private var amountFocused: Bool

    @AppStorage("alcoholEditorByDrink") private var alcoholByVolume = true
    @AppStorage("esterEditorByVolume") private var esterByVolume = false

    private var byDrinkPreferred: Bool {
        if isSolution { return solutionByVolume }
        return byVolumeCapability?.isMassPerVolume == true ? esterByVolume : alcoholByVolume
    }

    private var byDrinkBinding: Binding<Bool> {
        Binding(
            get: { byDrinkPreferred },
            set: { value in
                if isSolution {
                    solutionByVolume = value
                } else if byVolumeCapability?.isMassPerVolume == true {
                    esterByVolume = value
                } else {
                    alcoholByVolume = value
                }
            },
        )
    }

    var body: some View {
        Form {
            Section("Dose") {
                if let capability = byVolumeCapability {
                    let modes = ByVolumeDosing.modeLabels
                    Picker("Input", selection: byDrinkBinding) {
                        Text(modes.volume).tag(true)
                        Text(modes.mass).tag(false)
                    }
                    if byDrinkPreferred {
                        volumeFields(capability)
                    } else {
                        amountFields
                    }
                } else if let product = tabletProduct {
                    tabletFields(product)
                } else {
                    amountFields
                }
            }

            Section("Form") {
                Picker("Route", selection: $item.route) {
                    ForEach(RouteOfAdministration.allCases) { route in
                        Text(route.localizedName).tag(route)
                    }
                }
                if InjectionSite.applies(to: item.route) {
                    Picker("Injection Site", selection: injectionSite) {
                        Text("None").tag(InjectionSite?.none)
                        ForEach(InjectionSite.Area.offered(for: item.route), id: \.self) { area in
                            ForEach(InjectionSite.Side.allCases, id: \.self) { side in
                                let site = InjectionSite(area: area, side: side)
                                Text(verbatim: site.label).tag(Optional(site))
                            }
                        }
                    }
                }
                SaltPicker(
                    forms: item.librarySubstance?.saltForms(for: item.route) ?? [],
                    selection: $item.saltForm, style: .formRow,
                )
                EsterPicker(forms: item.esterForms(for: item.route), selection: $item.saltForm, style: .formRow)
                if !brandProducts.isEmpty { brandMenu }
                if showsIsomerPicker {
                    IsomerPicker(options: isomerPickerOptions, selection: $item.isomer, style: .formRow)
                }
            }

            if let lastDose, lastDose.showsBadge, time.isNow {
                Section {
                    EntryLevelEstimateCard(
                        substanceName: item.substanceName, lastDoseAmount: lastDose.lastDoseAmount,
                        lastDoseTimestamp: lastDose.lastDoseTimestamp, unit: lastDose.lastDoseUnit, route: lastDose.lastDoseRoute,
                    )
                }
            }
            if !time.isNow {
                Section {
                    LabeledContent("When", value: time.chipLabel)
                }
            }

            Section("Notes") {
                TextField("Add note…", text: $item.note, axis: .vertical)
                if profileStore.grapefruitLoggingEnabled, model.isGrapefruitSubstrate {
                    Toggle("Grapefruit", isOn: $item.hadGrapefruit)
                }
            }

            Section {
                Button("Remove", role: .destructive, action: onRemove)
            }
        }
        .navigationTitle(item.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .onAppear(perform: seedOnAppear)
        .onChange(of: item.route) { revalidateRoute() }
        .onChange(of: model.volumeText) { syncEnteredVolume() }
        .onChange(of: model.abvText) { syncEnteredVolume() }
        .onChange(of: model.drinkName) { syncCustomDrink() }
        .onChange(of: item.amount) {
            guard let capability = byVolumeCapability, !byDrinkPreferred else { return }
            model.reprojectVolumeFromGrams(item: &item, capability: capability)
        }
        .onChange(of: byDrinkPreferred) {
            if byDrinkPreferred {
                if isSolution { model.seedSolution(item: &item, context: modelContext) }
                model.seedByDrinkFieldsIfNeeded(from: item, capability: byVolumeCapability, force: true)
                syncCustomDrink()
            } else {
                if isSolution { model.clearSolution(item: &item) }
                model.showAmount(item.amount)
            }
        }
        .onChange(of: model.volumeUnit) { old, new in model.convertVolumeText(from: old, to: new) }
        .onChange(of: item.unit) {
            guard !isSolution, let capability = byVolumeCapability else { return }
            CustomDrinkPreset.seedIfNeeded(for: item.substanceName, capability: capability, context: modelContext)
            model.seedByDrinkFieldsIfNeeded(from: item, capability: capability)
        }
    }

    @ViewBuilder
    private var amountFields: some View {
        TextField(text: $model.amountText, prompt: item.isUnknownAmount ? Text("Unknown") : Text(verbatim: "0")) {
            Text("Amount")
        }
        .decimalKeyboard()
        .focused($amountFocused)
        .onChange(of: model.amountText) { model.commitAmountText(to: &item) }
        Picker("Dose unit", selection: $item.unit) {
            ForEach(model.unitMenuChoices(current: item.unit), id: \.self) { unit in
                Text(verbatim: unit).tag(unit)
            }
        }
        Stepper("Adjust Amount") {
            model.setAmount(item.amount + amountStep, item: &item)
        } onDecrement: {
            model.setAmount(max(0, item.amount - amountStep), item: &item)
        }
        if item.isUnknownAmount {
            Text("Logged with no number, so it stays out of curves, totals, and tolerance.")
                .foregroundStyle(.secondary)
        } else if model.amountTextIsUnreadable {
            Text("Can't tell if this separator marks decimals or thousands. Please retype the amount.")
                .foregroundStyle(.secondary)
        } else if let level = item.doseLevel {
            LabeledContent("Dose Level") { Text(level.displayName) }
        }
    }

    private var amountStep: Double {
        DoseStepping.step(referenceDose: item.referenceDose, amount: item.amount)
    }

    @ViewBuilder
    private func tabletFields(_ product: ProductStrengths) -> some View {
        Picker("Strength", selection: Binding(
            get: { model.pillStrength },
            set: { strength in
                if let strength {
                    model.selectStrength(strength, item: &item)
                } else {
                    model.selectFreeForm(item: item)
                }
            },
        )) {
            Text("Custom Amount").tag(Double?.none)
            ForEach(product.strengths, id: \.self) { strength in
                Text("\(strength.doseFormatted) mg").tag(Optional(strength))
            }
        }
        if model.pillStrength != nil {
            Stepper {
                Text(product.form == "capsule"
                    ? "^[\(model.pillCount) capsule](inflect: true)"
                    : "^[\(model.pillCount) tablet](inflect: true)")
            } onIncrement: {
                model.setPillCount(model.pillCount + 1, item: &item)
            } onDecrement: {
                model.setPillCount(model.pillCount - 1, item: &item)
            }
            LabeledContent("Amount", value: "\(item.totalAmount.doseFormatted) \(item.unit)")
        } else {
            amountFields
        }
    }

    @ViewBuilder
    private func volumeFields(_ capability: ByVolumeDosing) -> some View {
        if !isSolution {
            DrinkPresetMenu(
                substanceName: item.substanceName, selectedName: item.drinkName,
                isMassPerVolume: capability.isMassPerVolume,
            ) { preset in
                model.apply(preset: preset, item: &item, capability: capability, byDrinkPreferred: true)
            }
            NavigationLink {
                QuickLogDrinkPresets(substanceName: item.substanceName)
            } label: {
                Text(capability.isMassPerVolume ? "Edit concentrations…" : "Edit Drinks…")
            }
        }
        HStack {
            TextField(text: $model.abvText) { Text(capability.strengthFieldLabel) }
                .decimalKeyboard()
            Text(verbatim: capability.strengthUnitLabel).foregroundStyle(.secondary)
        }
        TextField("Volume", text: $model.volumeText).decimalKeyboard()
        Picker("Volume Unit", selection: $model.volumeUnit) {
            Text(verbatim: "mL").tag(UnitVolume.milliliters)
            Text(verbatim: "fl oz").tag(UnitVolume.fluidOunces)
        }
        if let amount = customDrinkGrams {
            LabeledContent("Amount", value: "\(amount.doseFormatted) \(capability.canonicalUnit)")
            if !capability.isMassPerVolume {
                let drinks = ByVolumeDosing.standardDrinks(grams: amount)
                LabeledContent("Standard Drinks", value: drinks.formatted(.number.precision(.fractionLength(1))))
            }
        } else {
            Text("Enter the concentration and volume.").foregroundStyle(.secondary)
        }
    }

    private var injectionSite: Binding<InjectionSite?> {
        Binding(
            get: { item.injectionSite },
            set: {
                item.injectionSite = $0
                item.injectionSiteTouched = true
            },
        )
    }

    private var brandMenu: some View {
        Menu {
            Button("Unbranded") { selectBrand(nil) }
            ForEach(brandProducts, id: \.name) { brand in
                Button(brand.name) { selectBrand(brand) }
            }
        } label: {
            LabeledContent("Brand", value: item.productName ?? String(localized: "Unbranded"))
        }
    }

    private func selectBrand(_ brand: SubstanceStore.BrandProduct?) {
        item.productName = brand?.name
        item.releaseForm = brand?.releaseForm
        item.isomer = nil
        model.pillSeeded = false
        if let product = tabletProduct { model.seedPillIfNeeded(product, item: &item) }
    }

    private func revalidateRoute() {
        let salts = item.librarySubstance?.saltForms(for: item.route) ?? []
        if salts.isEmpty {
            EsterPicker.revalidate(&item.saltForm, against: item.esterForms(for: item.route))
        } else {
            SaltPicker.revalidate(&item.saltForm, against: salts)
        }
        IsomerPicker.revalidate(&item.isomer, against: isomerPickerOptions)
        seedInjectionSite()
    }

    private func syncEnteredVolume() {
        guard byDrinkPreferred else { return }
        if customDrinkGrams == nil {
            item.amount = 0
            item.isUnknownAmount = false
        } else {
            syncCustomDrink()
        }
    }

    // MARK: - Item-derived gates

    /// The by-volume input for this staged dose: the substance's own (alcohol,
    /// an injectable ester), else a plain solution in the dose's unit per mL
    /// (``ByVolumeDosing/solution(in:)``), so any substance can be logged as a
    /// volume × concentration. A branded pill keeps its strength picker, and
    /// a substance whose own input is gated off here (estradiol by mouth)
    /// stays a mass log.
    private var byVolumeCapability: ByVolumeDosing? {
        if let capability = libraryVolumeCapability { return capability }
        guard item.librarySubstance?.byVolumeDosing == nil, tabletProduct == nil,
              ByVolumeDosing.solutionUnits.contains(item.unit) else { return nil }
        return .solution(in: item.unit)
    }

    /// Whether this dose's by-volume input is the generic solution rather than
    /// the substance's own.
    private var isSolution: Bool {
        libraryVolumeCapability == nil && byVolumeCapability != nil
    }

    /// The substance's own by-volume capability (alcohol), gated on the
    /// canonical "g" unit so the drink chips show only when the dose is in grams.
    private var libraryVolumeCapability: ByVolumeDosing? {
        guard let cap = item.librarySubstance?.byVolumeDosing,
              item.unit == cap.canonicalUnit else { return nil }
        return cap.offersVolumeInput(on: item.route) ? cap : nil
    }

    private var customDrinkGrams: Double? {
        model.customDrinkGrams(capability: byVolumeCapability)
    }

    /// The branded product's tablet/capsule strengths, when this staged dose is a
    /// known branded pill logged in mg — gates the pill picker. This is the med
    /// analogue of ``byVolumeCapability``: a real strength is picked as a chip and
    /// logged as a *pill*, rather than typed as raw milligrams. Nil for canonical
    /// logs, non-mg units, or brands with no curated strengths (→ plain mg stepper).
    private var tabletProduct: ProductStrengths? {
        guard item.unit == "mg", libraryVolumeCapability == nil,
              let product = item.productName, !product.isEmpty else { return nil }
        return SubstanceLibrary.productStrengths(for: product)
    }

    /// The substance's branded products, for the brand menu. Empty
    /// for substances with no brands.
    private var brandProducts: [SubstanceStore.BrandProduct] {
        guard let uid = item.librarySubstance?.substanceUID else { return [] }
        return SubstanceLibrary.brandProducts(forUID: uid)
    }

    /// The route's isomer options, for the isomer picker.
    private var isomerPickerOptions: [IsomerPicker.Option] {
        (item.librarySubstance?.isomerOptions(for: item.route) ?? []).map {
            IsomerPicker.Option(code: $0.code, displayName: $0.displayName)
        }
    }

    /// Whether to surface the isomer picker alongside the brand menu. The enantiomer
    /// axis is its own control: shown for a substance with no branded release form
    /// (Ketamine → Esketamine, Modafinil → Armodafinil) always, but on a *branded*
    /// substance only once a distinct enantiomer is active (Focalin searched into a
    /// D dose) — so a plain Methylphenidate log shows only the brand menu.
    private var showsIsomerPicker: Bool {
        guard isomerPickerOptions.count > 1 else { return false }
        return !brandProducts.contains(where: \.isExtendedRelease) || item.isomer != nil
    }

    private func seedOnAppear() {
        if let product = tabletProduct {
            model.seedPillIfNeeded(product, item: &item)
        }
        if item.amount > 0 {
            model.showAmount(item.amount)
        }
        if isSolution {
            // A row staged by volume reopens by volume; anything else is weighed.
            solutionByVolume = item.volumeML != nil && item.abv != nil
            if solutionByVolume { model.seedByDrinkFieldsIfNeeded(from: item, capability: byVolumeCapability) }
        }
        focusAmountIfWanted()
        seedInjectionSite()
        if profileStore.grapefruitLoggingEnabled {
            model.resolveGrapefruitSubstrate(substanceName: item.substanceName)
        }
        // Seed the custom-drink fields from a dose already logged by volume, so
        // re-opening it shows its strength/volume/name; a fresh draft takes the
        // substance's last by-volume log instead of opening on 0 / 0.
        if let capability = libraryVolumeCapability {
            CustomDrinkPreset.seedIfNeeded(for: item.substanceName, capability: capability, context: modelContext)
            model.seedFromLastByVolumeLog(item: &item, capability: capability, context: modelContext)
            model.seedByDrinkFieldsIfNeeded(from: item, capability: capability)
            model.drinkName = item.drinkName ?? ""
            model.drinkEmoji = item.emoji ?? ""
            syncCustomDrink()
        }
    }

    /// Offer the rotation's next site for an injected route, and fill it in
    /// until the user picks or clears one. A site whose area the new route
    /// doesn't offer (the abdomen on an intramuscular dose) is dropped.
    private func seedInjectionSite() {
        guard InjectionSite.applies(to: item.route) else {
            model.suggestedInjectionSite = nil
            item.injectionSite = nil
            return
        }
        let suggestion = InjectionSiteHistory.suggestedNext(
            substance: item.substanceName, route: item.route, in: modelContext,
        )
        model.suggestedInjectionSite = suggestion
        if let site = item.injectionSite, !InjectionSite.Area.offered(for: item.route).contains(site.area) {
            item.injectionSite = nil
        }
        if !item.injectionSiteTouched, item.injectionSite == nil {
            item.injectionSite = suggestion
        }
    }

    /// Raise the keyboard on the amount field when it is on screen and the row
    /// is one the user opened to type into (``StagedDose/wantsAmountFocus``),
    /// or when it opened empty. The field is absent for a branded pill (pick a
    /// strength) and the drink logger (presets are the primary action) — an
    /// ester in By Mass shows it and gets the focus.
    private func focusAmountIfWanted() {
        let fieldShown = tabletProduct == nil
            && (byVolumeCapability == nil || !byDrinkPreferred)
        let wanted = item.wantsAmountFocus || (item.amount <= 0 && libraryVolumeCapability == nil)
        if item.wantsAmountFocus { item.wantsAmountFocus = false }
        if fieldShown, wanted { amountFocused = true }
    }

    private func syncCustomDrink() {
        let capability = byVolumeCapability
        model.syncCustomDrink(item: &item, capability: capability, byDrinkPreferred: byDrinkPreferred)
    }
}

private struct DrinkPresetMenu: View {
    let selectedName: String?
    let isMassPerVolume: Bool
    let onSelect: (CustomDrinkPreset) -> Void

    @Query private var presets: [CustomDrinkPreset]

    init(
        substanceName: String,
        selectedName: String?,
        isMassPerVolume: Bool,
        onSelect: @escaping (CustomDrinkPreset) -> Void,
    ) {
        self.selectedName = selectedName
        self.isMassPerVolume = isMassPerVolume
        self.onSelect = onSelect
        let lower = substanceName.lowercased()
        _presets = Query(
            filter: #Predicate { $0.substanceName == lower },
            sort: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)],
        )
    }

    var body: some View {
        Menu {
            ForEach(presets) { preset in
                Button {
                    onSelect(preset)
                } label: {
                    Text(verbatim: preset.name)
                    Text(verbatim: preset.detailLabel)
                }
            }
        } label: {
            LabeledContent {
                Text(verbatim: selectedName ?? "")
            } label: {
                Text(isMassPerVolume ? "Concentration" : "Drink")
            }
        }
        .disabled(presets.isEmpty)
    }
}

extension CustomDrinkPreset {
    /// "330 mL and 5%" for an alcohol preset, "40 mg/mL" for an ester concentration
    /// preset (usually strength-only). Volume renders in the user's preferred unit.
    @MainActor var detailLabel: String {
        let strengthUnit = SubstanceLibrary.lookup(substanceName)?.byVolumeDosing?.strengthUnitLabel ?? "%"
        let sep = strengthUnit == "%" ? "" : " "
        let strength = "\(ByVolumeDosing.formatTrimmed(strengthABV))\(sep)\(strengthUnit)"
        guard let volumeML else { return strength }
        let unit = ByVolumeDefaults.preferredVolumeUnit
        let volume = Measurement(value: volumeML, unit: UnitVolume.milliliters).converted(to: unit)
        let formatted = volume.formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0 ... 1))))
        return [formatted, strength].formatted(.list(type: .and))
    }
}
