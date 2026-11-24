import SwiftUI

struct EntryLevelEstimateCard: View {
    let substanceName: String
    let lastDoseAmount: Double
    let lastDoseTimestamp: Date
    let unit: String
    let route: RouteOfAdministration

    private var remainingPercent: Double? {
        DosePK.status(substanceName: substanceName, route: route, lastDoseTimestamp: lastDoseTimestamp)
    }

    var body: some View {
        if let remainingPercent, remainingPercent > 5 {
            cardContent(remainingPercent: remainingPercent)
        }
    }

    private func cardContent(remainingPercent: Double) -> some View {
        let activeAmount = lastDoseAmount * remainingPercent / 100
        return HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: "info.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.accent)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("The model puts ≈\(activeAmount.doseFormatted) \(unit) of your \(lastDoseAmount.doseFormatted) \(unit) dose (\(timeAgo)) as still active, ~\(Int(remainingPercent))%")
                    .font(.caption)
                    .foregroundStyle(.primary)

                Text("An estimate from population data, not a measurement. It doesn't say when another dose is safe.")
                    .captionSecondary()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var timeAgo: String {
        switch DosePK.Elapsed(since: lastDoseTimestamp) {
        case let .minutes(m):
            String(localized: "\(m)m ago")
        case let .wholeHours(h):
            String(localized: "\(h)h ago")
        case let .hours(hours):
            String(localized: "\(hours.formatted(.number.precision(.fractionLength(1))))h ago")
        case let .days(d):
            String(localized: "\(d)d ago")
        }
    }
}
