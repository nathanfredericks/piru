import SwiftUI

struct StagedProductEditor: View {
    let product: CustomSubstanceEntry
    let model: DoseTrayModel
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var volume = StagedProductVolumeModel()

    private var quantity: Double {
        model.stagedQuantity(of: product) ?? 1
    }

    private var rows: [StagedDose] {
        model.staged.filter { $0.combinationName == product.name }
    }

    var body: some View {
        Form {
            Section("Quantity") {
                if product.isLiquidCombination {
                    TextField("Volume (mL)", text: $volume.text)
                        .decimalKeyboard()
                    Stepper("Adjust Volume") {
                        volume.adjust(1)
                    } onDecrement: {
                        volume.adjust(-1)
                    }
                    if volume.enteredML == nil {
                        Text("Enter a volume above zero.").foregroundStyle(.secondary)
                    }
                } else {
                    Stepper(value: Binding(
                        get: { Int(quantity) },
                        set: { model.setUnits($0, of: product) },
                    ), in: 1 ... CombinationComponent.maximumUnits) {
                        Text(verbatim: product.quantityLabel(quantity))
                    }
                }
            }
            Section("Components") {
                ForEach(rows) { row in
                    LabeledContent {
                        Text(verbatim: "\(row.totalAmount.doseFormatted) \(row.unit)")
                    } label: {
                        Text(verbatim: row.displayTitle)
                    }
                }
            }
            Section {
                Button("Remove", role: .destructive, action: onRemove)
            }
        }
        .navigationTitle(product.displayName ?? product.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .disabled(product.isLiquidCombination && volume.enteredML == nil)
            }
        }
        .onAppear { if product.isLiquidCombination { volume.show(quantity) } }
        .onChange(of: volume.text) {
            guard let entered = volume.enteredML, entered.doseFormatted != quantity.doseFormatted else { return }
            model.setVolume(entered, ofCombination: product.name)
        }
    }
}

/// The text behind a liquid product's volume field. Always mL: the product's
/// amounts are per mL, so the field takes no other unit.
@Observable
@MainActor
final class StagedProductVolumeModel {
    var text = ""

    /// The typed volume in mL, `nil` until the text is a positive number.
    var enteredML: Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = DecimalInput.parse(trimmed), value > 0
        else { return nil }
        return value
    }

    /// Show the staged volume in the field, unless the field already reads it
    /// — so a value the user is part-way through typing ("0." on the way to
    /// "0.25") is never rewritten.
    func show(_ volumeML: Double?) {
        guard let volumeML, volumeML > 0 else { return }
        if let enteredML, abs(enteredML - volumeML) < 0.0001 { return }
        text = volumeML.doseFormatted
    }

    /// The −/+ step: tenths of a milliliter under 2 mL (a dropper or an oral
    /// syringe), halves up to 10 mL, whole millilitres above.
    static func step(at volumeML: Double) -> Double {
        if volumeML < 2 { return 0.1 }
        if volumeML < 10 { return 0.5 }
        return 1
    }

    /// Bump the volume by one step, snapped to the step's grid and kept at or
    /// above the smallest step. The view hands the new volume to the tray,
    /// which rescales every component of the product.
    func adjust(_ direction: Double) {
        let current = enteredML ?? 0
        // Stepping down from a boundary uses the finer step below it, so 2 mL
        // goes to 1.9, not 1.5.
        let step = Self.step(at: direction < 0 ? max(current - 0.0001, 0) : current)
        let snapped = ((current + direction * step) / step).rounded() * step
        let next = min(max(snapped, Self.step(at: 0)), CombinationComponent.maximumVolumeML)
        text = next.doseFormatted
    }
}
