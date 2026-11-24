import SwiftData
import SwiftUI

/// Interactions, the meal's onset delay and the late-dose sleep clause share one
/// section so they stay visible before recording.
struct TrayWarningBanner: View {
    let model: DoseTrayModel
    /// Holds the recent dose log the interaction check reads, so a staged dose
    /// is checked against what is already in the body.
    let content: QuickLogContentModel

    @Environment(\.modelContext) private var modelContext
    @Environment(\.profileDirectory) private var directory

    var body: some View {
        let timestamp = model.time.resolved
        let shown = TrayInteractionCheck.warnings(
            staged: model.staged.map(\.substanceName),
            history: history(at: timestamp),
            at: timestamp,
        )
        let sleepWarnings = model.staged.compactMap { dose -> (name: String, end: Date)? in
            guard let end = MedTimeConsequence.nightEnd(
                substance: dose.librarySubstance, route: dose.route, at: timestamp,
            ) else { return nil }
            return (dose.productName ?? dose.substanceName, end)
        }
        let mealLines = TrayMealConsequence.lines(staged: model.staged, meal: model.meal)
        return Group {
            if !shown.isEmpty || !sleepWarnings.isEmpty || !mealLines.isEmpty {
                Section("Before Recording") {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, warning in
                        warningRow(
                            symbol: warning.severity == .dangerous
                                ? warning.mechanism.filledIconName : warning.mechanism.iconName,
                            color: warning.severity.labelColor,
                            detail: warning.counterpart?.trayLine,
                        ) {
                            Text(warning.leadClause)
                        }
                    }
                    ForEach(Array(mealLines.enumerated()), id: \.offset) { _, line in
                        TrayMealLineRow(line: line)
                    }
                    if let latest = sleepWarnings.map(\.end).max() {
                        let names = sleepWarnings.map(\.name).formatted(.list(type: .and))
                        warningRow(symbol: DosePhaseGlyph.sleep, color: Color.Semantic.Caution.text) {
                            Text("\(names) modeled active until ~\(Self.clock(latest))")
                        }
                    }
                }
            }
        }
    }

    /// `detail` is a second, quieter line under the warning — the logged dose
    /// an interaction is with, which the tray has no other way to show.
    private func warningRow(
        symbol: String,
        color: Color,
        detail: String? = nil,
        @ViewBuilder text: () -> Text,
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.caption)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                text()
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color)
                if let detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryLabel)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func history(at date: Date) -> [DoseEntry] {
        let cutoff = date.addingTimeInterval(-QuickLogContentModel.recentEntriesSpan)
        if model.recipientID == nil, model.time.isNow {
            // Invalidate the observation-ignored history snapshot after a commit.
            _ = content.recentEntriesGeneration
            return content.recentEntries.filter { !$0.isDeleted }
        }

        let context: ModelContext
        if let id = model.recipientID, id != directory.activeProfileID {
            guard let container = directory.container(for: id, writable: false) else { return [] }
            context = container.mainContext
        } else {
            context = modelContext
        }
        let descriptor = FetchDescriptor<DoseEntry>(
            predicate: #Predicate { $0.timestamp >= cutoff && $0.timestamp <= date },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)],
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
