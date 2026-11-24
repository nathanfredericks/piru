import SwiftUI

/// The shareable substance card, tinted by the substance's category color.
struct SubstanceShareCard: View {
    let substance: Substance
    let route: SubstanceRoute?
    let molecule: MoleculeStructure?
    /// The reported effects, merged once here (see ``merged(_:)``) rather than
    /// on each of the several reads per render.
    let dedupedReportedEffects: [ReportedEffect]

    init(
        substance: Substance,
        route: SubstanceRoute?,
        molecule: MoleculeStructure?,
        reportedEffects: [ReportedEffect] = [],
    ) {
        self.substance = substance
        self.route = route
        self.molecule = molecule
        dedupedReportedEffects = Self.merged(reportedEffects)
    }

    private var accent: Color {
        substance.category.color
    }

    // MARK: shared data

    private var doseText: [Int: String] {
        guard let route else { return [:] }
        return route.doses.bandDoseText(unit: route.unit)
    }

    private var topEffects: [String] {
        substance.subjectiveEffects.prefix(6).map(\.name)
    }

    /// Reported effects merged by their resolved display name — drug.community
    /// often lists the same effect under several phrasings that collapse to one
    /// localized vocab term (e.g. "increased sociability" + "emotional bonding").
    /// Merging sums the report counts and keeps the earliest emergence band.
    private static func merged(_ reportedEffects: [ReportedEffect]) -> [ReportedEffect] {
        var byName: [String: ReportedEffect] = [:]
        for effect in reportedEffects {
            if let existing = byName[effect.displayName] {
                byName[effect.displayName] = ReportedEffect(
                    name: existing.name,
                    displayName: existing.displayName,
                    domain: existing.domain,
                    reportCount: existing.reportCount + effect.reportCount,
                    emergesBand: [existing.emergesBand, effect.emergesBand].compactMap(\.self).min(),
                )
            } else {
                byName[effect.displayName] = effect
            }
        }
        // Stable order (count desc, then name) so a substance always renders the
        // same card — dictionary iteration order is otherwise nondeterministic.
        return byName.values.sorted {
            $0.reportCount != $1.reportCount ? $0.reportCount > $1.reportCount : $0.displayName < $1.displayName
        }
    }

    private var frequencyEffects: [ReportedEffect] {
        Array(dedupedReportedEffects.prefix(5))
    }

    private var hasBandedEffects: Bool {
        dedupedReportedEffects.contains { $0.emergesBand != nil }
    }

    /// The ramp rows: top-2 by report count from each band Light…Heavy (1…4), laid
    /// out band-ascending so the ribbon always spans the full arc — including the
    /// heavy-dose caution effects.
    private var rampEffects: [RampEffect] {
        var out: [RampEffect] = []
        for band in 1 ... 4 {
            let inBand = dedupedReportedEffects
                .filter { $0.emergesBand == band }
                .sorted { $0.reportCount > $1.reportCount }
                .prefix(2)
            out.append(contentsOf: inBand.map {
                RampEffect(name: $0.displayName, color: $0.domain.color, count: $0.reportCount, band: band)
            })
        }
        return out.sorted { $0.band != $1.band ? $0.band < $1.band : $0.count > $1.count }
    }

    // MARK: body

    var body: some View {
        compactCard
            .frame(width: Self.cardWidth, alignment: .leading)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay(plateBorder)
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.white)
    }

    /// The card's outer corner radius; the plate border and panels round
    /// concentrically off it.
    private static let cardWidth: CGFloat = 440
    private static let cornerRadius: CGFloat = 34
    /// Inset of the plate border from the card edge.
    private static let borderInset: CGFloat = 13

    /// A vibrant diagonal wash that stays in the class hue (empathogen pink-red,
    /// stimulant orange…) — brightened at the top-left, gently deepened toward the
    /// bottom-right so white text and the skeleton keep contrast without ever
    /// crushing to black.
    private var background: some View {
        LinearGradient(
            colors: [accent.mix(with: .white, by: 0.16), accent.mix(with: .black, by: 0.30)],
            startPoint: .topLeading, endPoint: .bottomTrailing,
        )
        .overlay(
            RadialGradient(
                colors: [accent.mix(with: .white, by: 0.34).opacity(0.6), .clear],
                center: .topTrailing, startRadius: 0, endRadius: Self.cardWidth * 0.95,
            ),
        )
    }

    /// A hairline inset frame — the "plate" edge that makes the card read as a
    /// printed specimen. `RoundedRectangle.inset(by:)` already shrinks the corner
    /// radius by the inset (the same trick `strokeBorder` uses), so it must be given
    /// the *full* outer radius — the inset then yields `cornerRadius − borderInset`,
    /// staying concentric with the card's outer corner. Subtracting the inset from
    /// the radius here too would double-count and pinch the border's corners.
    private var plateBorder: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .inset(by: Self.borderInset)
            .stroke(.white.opacity(0.22), lineWidth: 1)
            .allowsHitTesting(false)
    }

    // MARK: - Composition

    private var compactCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            heroPanel(height: 176)
            if !doseText.isEmpty { doseLadder }
            if let duration = route?.duration { phaseTrio(duration) }
            effectsSection
            Spacer(minLength: 0)
            footer
        }
        .padding(26)
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text(substance.displayTitle)
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(2)
            subtitleRow
        }
    }

    private var subtitleRow: some View {
        HStack(spacing: Spacing.md) {
            categoryChip
            if let formula = substance.formula {
                Text(formula)
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
    }

    private var categoryChip: some View {
        Text(substance.category.displayName)
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .tracking(0.6)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, 5)
            .background(.white.opacity(Theme.Opacity.tintActive), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(Theme.Opacity.emphasis), lineWidth: 1))
    }

    // MARK: hero (molecule specimen)

    private func heroPanel(height: CGFloat) -> some View {
        panel {
            if let molecule {
                MoleculeStructureView(structure: molecule, color: .white, lineWidth: 2.2)
                    .padding(18)
            } else {
                Image(systemName: "atom")
                    .font(.system(size: 60, weight: .thin))
                    .foregroundStyle(.white.opacity(Theme.Opacity.dimmed))
                    .accessibilityHidden(true)
            }
        }
        .frame(height: height)
    }

    // MARK: dose ladder

    private static let ladder: [(Int, LocalizedStringKey)] = [
        (0, "Threshold"), (1, "Light"), (2, "Common"), (3, "Strong"), (4, "Heavy"),
    ]

    private var doseLadder: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionLabel("Dose")
                Spacer()
                if let route {
                    Text(route.route.localizedName)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.bottom, Spacing.sm)
                }
            }
            doseLadderRows
        }
    }

    /// Row height shared by the dose ladder and effect bars.
    private static let dataRowHeight: CGFloat = 34

    private var doseLadderRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.ladder, id: \.0) { index, name in
                if let text = doseText[index] {
                    HStack(spacing: 9) {
                        DoseTierMark(level: index, diameter: 18)
                        Text(name)
                            .font(.subheadline.weight(index == 2 ? .bold : .regular))
                            .foregroundStyle(index == 2 ? .white : .white.opacity(0.75))
                        Spacer()
                        Text(text)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                    .frame(height: Self.dataRowHeight)
                    .overlay(alignment: .bottom) {
                        if index != 4, doseText[index + 1] != nil {
                            Rectangle().fill(.white.opacity(Theme.Opacity.tint)).frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    // MARK: one-row onset · peak · total

    private func phaseTrio(_ duration: DurationProfile) -> some View {
        HStack(spacing: 0) {
            trioCell(DosePhaseGlyph.comeup, "Onset", duration.onset)
            trioDivider
            trioCell(DosePhaseGlyph.peak, "Peak", duration.peak)
            trioDivider
            trioCell("clock", "Total", duration.total)
        }
        .background(.white.opacity(Theme.Opacity.hairline), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var trioDivider: some View {
        Rectangle().fill(.white.opacity(Theme.Opacity.tint)).frame(width: 1, height: 44)
    }

    private func trioCell(_ symbol: String, _ name: LocalizedStringKey, _ range: DurationRange?) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .accessibilityHidden(true)
                .foregroundStyle(.white.opacity(0.75))
            Text(range?.compactString ?? "—")
                .font(.system(size: 15, weight: .heavy, design: .rounded).monospacedDigit())
            Text(name)
                .font(.system(size: 9, weight: .bold))
                .textCase(.uppercase).tracking(0.5)
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.lg)
    }

    // MARK: effects section (ramp / columns / fallback)

    @ViewBuilder private var effectsSection: some View {
        if hasBandedEffects {
            VStack(alignment: .leading, spacing: Spacing.md) {
                sectionLabel("Most common effects by dose")
                EmergenceRamp(rows: rampEffects, nameWidth: 158, font: 10)
            }
        } else if !frequencyEffects.isEmpty {
            frequencyBars
        } else if !topEffects.isEmpty {
            effectChips
        }
    }

    // MARK: effects fallback (flat frequency list)

    private var effectChips: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionLabel("Reported effects")
            FlowChips(items: topEffects)
        }
    }

    /// Compact report count — "1.2k" past a thousand, plain otherwise.
    private static func compactCount(_ n: Int) -> String {
        n >= 1_000 ? "\(n / 1_000).\((n % 1_000) / 100)k" : "\(n)"
    }

    private var frequencyBars: some View {
        let maxCount = max(frequencyEffects.map(\.reportCount).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 9) {
            sectionLabel("Most reported")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(frequencyEffects) { effect in
                    HStack(spacing: Spacing.lg) {
                        LegendDot(color: effect.domain.color, size: .compact)
                        Text(effect.displayName)
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.14))
                                Capsule().fill(effect.domain.color.opacity(0.9))
                                    .frame(width: max(8, geo.size.width * CGFloat(effect.reportCount) / CGFloat(maxCount)))
                            }
                        }
                        .frame(width: 64, height: 7)
                        Text(verbatim: Self.compactCount(effect.reportCount))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 30, alignment: .trailing)
                    }
                    .frame(height: Self.dataRowHeight)
                }
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        footerContent.padding(.top, Spacing.xxs)
    }

    private var footerContent: some View {
        HStack(spacing: Spacing.md) {
            footerBrand
            Spacer()
            Text(verbatim: "kagerou.glass/piru")
                .font(.system(.caption2, design: .rounded).weight(.medium))
                .foregroundStyle(.white.opacity(Theme.Opacity.dimmed))
        }
    }

    private var footerBrand: some View {
        HStack(spacing: Spacing.md) {
            Image("AppIconArtwork")
                .resizable().interpolation(.high)
                .frame(width: IconSize.iconMini, height: IconSize.iconMini)
                .accessibilityHidden(true)
            Text(verbatim: "Piru")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
        }
    }

    // MARK: shared bits

    private func sectionLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption2.weight(.bold)).textCase(.uppercase).tracking(0.6)
            .foregroundStyle(.white.opacity(0.55))
            .padding(.bottom, Spacing.sm)
    }

    /// The frosted specimen panel for the molecule.
    private func panel(@ViewBuilder _ content: () -> some View) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(.white.opacity(Theme.Opacity.tint))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.15), lineWidth: 1))
            content()
        }
    }
}

// MARK: - Dose tier mark

/// A distinct per-tier mark for the dose scale — each tier its own symbol rather
/// than one gauge "filling up." The set escalates from a faint speck to a caution
/// triangle, so a heavier dose reads as *more hazardous*, never as the "full" or
/// "complete" state a filling ring wrongly implied. Shared by the dose ladder and
/// the effect ramp's tier header so both read on one scale.
private struct DoseTierMark: View {
    let level: Int // 0 threshold, 1 light, 2 common, 3 strong, 4 heavy
    var diameter: CGFloat = 18

    private var symbol: String {
        switch level {
        case 0: "circle.dotted"
        case 1: "circle"
        case 2: "circle.fill"
        case 3: "exclamationmark.circle.fill"
        default: "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: diameter * 0.82))
            .foregroundStyle(.white.opacity(level == 0 ? 0.5 : level >= 3 ? 0.95 : 0.78))
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}

// MARK: - Emergence ramp

/// One effect row for the ramp.
private struct RampEffect: Identifiable {
    let id = UUID()
    let name: String
    let color: Color
    let count: Int
    let band: Int // 1 light … 4 heavy
}

/// A dose-emergence ribbon: each effect is a pill from the dose where it emerges to
/// the heavy edge; pill THICKNESS ∝ report frequency (log-normalized so a huge
/// outlier doesn't crush the rest), the raw count shown small beside the name, and
/// a ``DoseDial`` header marking each tier.
private struct EmergenceRamp: View {
    let rows: [RampEffect]
    var nameWidth: CGFloat
    var font: CGFloat

    private static let rowH: CGFloat = 30
    private static let headerH: CGFloat = 24
    private static let countW: CGFloat = 34
    private static let tailFrac: CGFloat = 0.14 // Heavy tick sits in from the edge

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let axisW = width - nameWidth
            let tierW = axisW * (1 - Self.tailFrac)
            let barEnd = nameWidth + axisW
            let bandX: (Int) -> CGFloat = { nameWidth + tierW * CGFloat($0 - 1) / 3 }
            let gridHeight = Self.headerH + CGFloat(rows.count) * Self.rowH - 6

            ZStack(alignment: .topLeading) {
                ForEach(1 ... 4, id: \.self) { band in
                    Rectangle().fill(.white.opacity(Theme.Opacity.tint))
                        .frame(width: 1, height: gridHeight)
                        .position(x: bandX(band), y: Self.headerH + (gridHeight - Self.headerH) / 2 - 3)
                    DoseTierMark(level: band, diameter: 18)
                        .position(x: bandX(band), y: Self.headerH / 2)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, effect in
                    let cy = Self.headerH + CGFloat(index) * Self.rowH + Self.rowH / 2
                    let startX = bandX(effect.band)
                    let thickness = self.thickness(effect.count)
                    Capsule().fill(effect.color.opacity(0.82))
                        .frame(width: max(thickness, barEnd - startX), height: thickness)
                        .position(x: (startX + barEnd) / 2, y: cy)
                    Text(effect.name)
                        .font(.system(size: font))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .frame(width: nameWidth - Self.countW - 12, alignment: .trailing)
                        .position(x: (nameWidth - Self.countW - 12) / 2, y: cy)
                    Text(Self.compact(effect.count))
                        .font(.system(size: font - 1, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(Theme.Opacity.dimmed))
                        .frame(width: Self.countW, alignment: .trailing)
                        .position(x: nameWidth - Self.countW / 2 - 8, y: cy)
                }
            }
        }
        .frame(height: Self.headerH + CGFloat(rows.count) * Self.rowH + 4)
    }

    private func thickness(_ count: Int) -> CGFloat {
        let counts = rows.map { Double($0.count) }
        let lo = log(counts.min() ?? 1), hi = log(counts.max() ?? 1)
        let normalized = hi > lo ? (log(Double(count)) - lo) / (hi - lo) : 0.5
        return 7 + CGFloat(normalized) * 16 // 7…23pt
    }

    private static func compact(_ n: Int) -> String {
        n >= 1_000 ? "\(n / 1_000).\((n % 1_000) / 100)k" : "\(n)"
    }
}

private struct FlowChips: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 7) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, 5)
                    .background(.white.opacity(Theme.Opacity.tintActive), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }
}
