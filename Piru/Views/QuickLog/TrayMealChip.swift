import SwiftUI

/// One line of what the picked meal does. `estimatedFor` names the substance
/// when the figure is the generic delay rather than its own measured one.
struct TrayMealLine {
    let text: Text
    var estimatedFor: String?
}

/// What the picked meal does to the staged oral doses, as the lines
/// ``TrayWarningBanner`` shows before recording. One line per dose up to two, then a summary.
enum TrayMealConsequence {
    @MainActor
    static func lines(staged: [StagedDose], meal: MealState?) -> [TrayMealLine] {
        guard let meal, meal.fedFraction > 0 else { return [] }
        let delays: [(name: String, delay: MealOnsetDelay)] = staged.compactMap { item in
            guard let delay = meal.onsetDelay(
                forSubstance: item.substanceName, product: item.productName, route: item.route,
            ) else { return nil }
            return (item.productName ?? item.librarySubstance?.displayTitle ?? item.substanceName, delay)
        }
        guard delays.count > 2 else {
            return delays.map { line(meal: meal, name: $0.name, delay: $0.delay) }
        }
        let delayed = delays.filter { $0.delay.minutes >= 1 }
        guard let longest = delayed.map(\.delay.minutes).max() else {
            return [TrayMealLine(text: Text("Food doesn't delay these doses"))]
        }
        let shift = MealOnsetDelay.formatted(longest)
        let count = delayed.count
        return [TrayMealLine(text: meal == .full
                ? Text("A meal delays ^[\(count) dose](inflect: true) by up to ~\(shift)")
                : Text("A snack delays ^[\(count) dose](inflect: true) by up to ~\(shift)"))]
    }

    /// An estimated shift carries a dotted underline instead of a worded
    /// caveat; tapping the line says what it's an estimate of.
    private static func line(meal: MealState, name: String, delay: MealOnsetDelay) -> TrayMealLine {
        guard delay.minutes >= 1 else { return TrayMealLine(text: Text("Food doesn't delay **\(name)**")) }
        var shift = AttributedString("~" + MealOnsetDelay.formatted(delay.minutes))
        if delay.isGeneric {
            shift.underlineStyle = Text.LineStyle(pattern: .dot)
        }
        let text = meal == .full
            ? Text("A meal delays **\(name)** by \(shift)")
            : Text("A snack delays **\(name)** by \(shift)")
        return TrayMealLine(text: text, estimatedFor: delay.isGeneric ? name : nil)
    }
}

/// A meal line in the warnings. An estimated one is a button whose popover says
/// the figure is the typical delay, since no study measured this substance.
struct TrayMealLineRow: View {
    let line: TrayMealLine

    @State private var showsExplanation = false

    var body: some View {
        if let name = line.estimatedFor {
            Button { showsExplanation = true } label: { row }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Typical estimate"))
                .popover(isPresented: $showsExplanation, arrowEdge: .bottom) {
                    Text("A typical delay for oral doses. No food study has measured **\(name)** itself.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 260, alignment: .leading)
                        .padding(Spacing.xl)
                        .presentationCompactAdaptation(.popover)
                }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Image(systemName: "fork.knife")
                .font(.caption)
                .accessibilityHidden(true)
            line.text
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(Theme.secondaryLabel)
    }
}
