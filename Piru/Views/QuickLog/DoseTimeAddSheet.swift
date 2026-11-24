import SwiftUI

struct DoseTimePresetForm: View {
    let existing: [Int]
    let onAdd: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hours = 0
    @State private var minutes = 0

    private var total: Int { hours * 60 + minutes }

    var body: some View {
        Form {
            Stepper("Hours: \(hours)", value: $hours, in: 0 ... 23)
            Stepper("Minutes: \(minutes)", value: $minutes, in: 0 ... 59)
            if existing.contains(total) { Text("That preset already exists.") }
        }
        .navigationTitle("Add Preset")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    onAdd(total)
                    dismiss()
                }
                .disabled(!DoseTimeDefaults.range.contains(total) || existing.contains(total))
            }
        }
    }
}
