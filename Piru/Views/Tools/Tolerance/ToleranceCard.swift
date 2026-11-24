import Charts
import SwiftUI

/// A mechanism class's modeled tolerance, recovery chart, and safety notes.
struct ToleranceCard: View {
    let row: ToleranceRow

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            ToleranceCardHeader(
                color: row.familyColor,
                name: row.snapshot.receptorClass.casualName,
            )

            // Effect-selective classes (GABA, α2δ) split into the effect ladder instead of one gauge:
            // sedation fades while memory and coordination do not, which one bar cannot say.
            if row.snapshot.effectShifts.isEmpty {
                ToleranceBar(
                    bands: row.bands,
                    level: row.snapshot.severity,
                )
            } else {
                EffectLadderView(snapshot: row.snapshot)
            }

            ToleranceRecoveryChart(row: row)

            ToleranceSafetyNotesView(notes: row.safetyNotes())
        }
        .padding(.vertical, Spacing.sm)
    }
}

struct ToleranceCardHeader: View {
    let color: Color
    let name: LocalizedStringResource

    var body: some View {
        HStack(spacing: Spacing.md) {
            LegendDot(color: color, size: .large)
            Text(name)
                .cardTitle()
            Spacer(minLength: 8)
            Text("Modeled")
                .capsuleChip(text: Theme.secondaryLabel, fill: .secondary, size: .regular)
                .textCase(.uppercase)
        }
    }
}

/// The segmented, part-to-whole tolerance bar: how toleranced you are, split by which recovery layer.
struct ToleranceBar: View {
    let bands: [ToleranceBand]
    /// Overall fill, 0–1 — spoken to VoiceOver as a share of the bar.
    let level: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(Theme.Opacity.tintActive))
                HStack(spacing: bands.count > 1 ? 1.5 : 0) {
                    ForEach(bands) { band in
                        Rectangle()
                            .fill(band.color)
                            .frame(width: max(0, geometry.size.width * band.widthFraction))
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Modeled tolerance"))
        .accessibilityValue(Text(min(1, max(0, level)), format: .percent.precision(.fractionLength(0))))
    }
}

/// The per-card recovery chart (linear, gridded, starts at the current level, days). Skipped when
/// essentially rested (nothing to plot) or when the recovery window is under a couple of hours — too
/// short to plot without a degenerate, repeated-tick axis.
struct ToleranceRecoveryChart: View {
    let row: ToleranceRow

    var body: some View {
        if row.snapshot.severity > 0.03, row.recoveryWindowMinutes >= 120 {
            let points = row.recoveryCurve(overMinutes: row.recoveryWindowMinutes)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Chart {
                    ForEach(points) { point in
                        LineMark(
                            x: .value("Days", point.day),
                            y: .value("Tolerance", point.percent),
                        )
                        .foregroundStyle(row.familyColor)
                        .interpolationMethod(.monotone)
                    }
                    if let start = points.first {
                        PointMark(
                            x: .value("Days", start.day),
                            y: .value("Tolerance", start.percent),
                        )
                        .foregroundStyle(row.familyColor)
                        .symbolSize(45)
                    }
                }
                .chartYScale(domain: 0 ... 100)
                .chartYAxis {
                    AxisMarks(values: [0, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let percent = value.as(Int.self) {
                                Text(percent >= 100 ? "high" : "low")
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: row.xAxisDays) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let days = value.as(Double.self) {
                                Text(axisDayLabel(days: days))
                            }
                        }
                    }
                }
                .frame(height: 92)
                .chartSummaryAccessibility(
                    label: Text("Modeled tolerance over time"),
                    value: Text("The modeled level from now, fading over the days shown."),
                )
            }
        }
    }
}

/// The trimmed one-sentence safety notes for a class (one label each).
struct ToleranceSafetyNotesView: View {
    let notes: [ToleranceSafetyNote]

    var body: some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(notes) { note in
                    Label {
                        Text(note.text)
                            .captionSecondary()
                    } icon: {
                        Image(systemName: note.systemImage)
                            .foregroundStyle(note.tint)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }
}
