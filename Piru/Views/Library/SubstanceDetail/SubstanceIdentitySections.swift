import SwiftUI

/// Name / aliases / route — demoted below dosing and collapsed by default; few
/// users need the chemical identity up front. Chemists who want the full
/// identity follow the PubChem link in the Chemistry disclosure below.
struct InfoDisclosureSection: View {
    let substance: Substance
    let model: SubstanceDetailModel

    @State private var infoExpanded = false
    @State private var aliasesExpanded = false

    var body: some View {
        CollapsibleSection("Additional Info", isExpanded: $infoExpanded) {
            let extras = infoExtraCells
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                GridRow {
                    GridCell("Category", String(localized: substance.category.displayName))
                    GridCell("Default route", String(localized: substance.defaultRoute.localizedName))
                }
                if !extras.isEmpty {
                    GridRow {
                        GridCell(extras[0].0, extras[0].1)
                        if extras.count > 1 { GridCell(extras[1].0, extras[1].1) } else { Color.clear }
                    }
                }
            }
            .padding(.vertical, Spacing.xs)

            if !substance.displayAliases.isEmpty {
                aliasChips
            }
            // One row per tags+footer — see the layout rationale on
            // `SourceAttributionRow` in SubstanceDetailSupport.swift.
            VStack(alignment: .leading, spacing: 0) {
                if !substance.tags.isEmpty {
                    SubstanceTagFlow(tags: substance.tags, accent: substance.category.color)
                        .padding(.top, Spacing.xs)
                }
                if let slug = model.provenance?.categorySource {
                    SourceAttributionRow(
                        slug: slug,
                        label: "Category",
                        deepLink: SubstanceSourceLinks.deepLink(slug, substance: substance),
                        substanceName: substance.name, field: .category,
                    )
                }
                if let slug = model.provenance?.halfLifeSource, substance.halfLifeMinutes != nil {
                    SourceAttributionRow(
                        slug: slug,
                        label: "Half-life",
                        deepLink: SubstanceSourceLinks.deepLink(slug, substance: substance),
                        substanceName: substance.name, field: .halfLife,
                    )
                }
            }
        }
    }

    /// Optional second-row identity cells — availability and (benzodiazepines
    /// only) the cross-benzo diazepam equivalent. Empty for most compounds.
    private var infoExtraCells: [(LocalizedStringResource, String)] {
        var cells: [(LocalizedStringResource, String)] = []
        if let reg = substance.regulatoryStatus {
            cells.append(("Availability", Self.regulatoryDisplay(reg)))
        }
        if substance.displayClass.showsDoseLadder, let dz = substance.diazepamEquivalent, let text = dz.displayText {
            cells.append(("Diazepam equivalent", text))
        }
        // The source's own figure, which for most substances is a range rather than a point
        // value — see `HalfLife.displayText`. The attribution row above says where it is from.
        if let halfLife = substance.halfLife {
            cells.append(("Half-life", halfLife.displayText))
        }
        return cells
    }

    /// Aliases as a wrapping chip flow, collapsed to the first few with a
    /// "+N more" chip — a long comma list was a single over-tall row before.
    private var aliasChips: some View {
        let all = substance.displayAliases
        let limit = 5
        let shown = aliasesExpanded ? all : Array(all.prefix(limit))
        let hidden = all.count - shown.count
        return VStack(alignment: .leading, spacing: 7) {
            Text("Also known as")
                .font(.caption2)
                .foregroundStyle(Theme.secondaryLabel)
                .textCase(.uppercase)
            FlowLayout(spacing: Spacing.sm) {
                ForEach(shown, id: \.self) { alias in
                    aliasChip(Text(alias))
                        .textSelection(.enabled)
                }
                if hidden > 0 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { aliasesExpanded = true }
                    } label: {
                        aliasChip(Text("+\(hidden) more"), accent: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private func aliasChip(_ text: Text, accent: Bool = false) -> some View {
        text
            .font(.caption.weight(.medium))
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.xs)
            .background(
                accent ? Theme.accent.opacity(Theme.Opacity.tint) : Color.platformTertiarySystemFill,
                in: Capsule(),
            )
            .foregroundStyle(accent ? Theme.accent : Theme.secondaryLabel)
    }

    /// Human-readable availability label from the parsed regulatory_status.
    private static func regulatoryDisplay(_ raw: String) -> String {
        switch raw {
        case "otc": return String(localized: "Over-the-counter")
        case "rx": return String(localized: "Prescription only")
        case "rx_otc_dependent": return String(localized: "OTC / Prescription")
        default:
            if raw.hasPrefix("controlled_schedule_"), let n = raw.split(separator: "_").last {
                return String(localized: "Schedule \(String(n)) (controlled)")
            }
            return raw
        }
    }
}

/// Chemical identity (formula / molar mass / CAS / InChIKey) folded into a
/// collapsed disclosure below the identity Info card. Every value is selectable
/// and carries a Copy action — an InChIKey you can't copy is useless.
struct ChemistrySection: View {
    let substance: Substance
    let moleculeStructure: MoleculeStructure?

    @State private var chemistryExpanded = false
    @Environment(\.openURL) private var openURL

    /// Whether the substance holds any chemistry to show. Gates on data we
    /// actually hold: `pubChemURL` cannot be part of this test, since it falls
    /// back to a name-search URL, is non-nil for every substance in the
    /// library, and would render the card for all of them — as an empty grid
    /// whenever nothing else resolved.
    static func hasData(for substance: Substance) -> Bool {
        substance.formula != nil || substance.cas != nil || substance.inchikey != nil
            || substance.molarMass != nil || substance.pubchemCID != nil || substance.smiles != nil
            || substance.iupacName != nil || (substance.physicochemical?.hasAnyValue ?? false)
    }

    var body: some View {
        let hasPubChem = substance.pubchemCID != nil
        let phys = substance.physicochemical
        if Self.hasData(for: substance) {
            CollapsibleSection("Chemistry", isExpanded: $chemistryExpanded) {
                // The molecule hero — omitted entirely when the substance has
                // no generated structure (no SMILES, or obabel couldn't parse
                // it).
                if substance.smiles != nil, let moleculeStructure {
                    // The view fits its own aspect ratio, so wide molecules stay
                    // short instead of floating in whitespace; cap the height so a
                    // tall/near-square one doesn't dominate the card.
                    MoleculeStructureView(structure: moleculeStructure, formula: substance.formula)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 150)
                        .padding(.bottom, Spacing.xs)
                }
                let showMW = substance.molarMass != nil && !substance.usesPeptidePresentation
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                    if substance.formula != nil || showMW {
                        GridRow {
                            if let f = substance.formula { GridCell("Formula", f) } else { Color.clear }
                            if showMW, let mw = substance.molarMass {
                                GridCell("Molar mass", "\(mw.doseFormatted) g/mol")
                            } else { Color.clear }
                        }
                    }
                    physicochemicalRows(phys)
                    if let iupac = substance.iupacName {
                        GridRow { GridCell("IUPAC name", iupac).gridCellColumns(2) }
                    }
                    if let smiles = substance.smiles {
                        GridRow { GridCell("SMILES", smiles, mono: true).gridCellColumns(2) }
                    }
                    if let k = substance.inchikey {
                        GridRow { GridCell("InChIKey", k, mono: true).gridCellColumns(2) }
                    }
                    if substance.cas != nil || hasPubChem {
                        GridRow {
                            if let c = substance.cas { GridCell("CAS", c, mono: true) } else { Color.clear }
                            if let cid = substance.pubchemCID, let url = substance.pubChemURL {
                                pubChemCell(cid: cid, url: url)
                            } else { Color.clear }
                        }
                    }
                }
                .padding(.vertical, Spacing.xs)
                if let phys, phys.hasAnyValue {
                    // States where the numbers come from rather than warning the
                    // reader off them. They are computed from the structure, which
                    // is the best available data for most of these compounds, so
                    // the line never words that as a defect ("not measured").
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Computed from the molecular structure (PubChem, NPS-DataHub) rather than measured in a lab.")
                        if phys.hasLD50 {
                            Text("LD50 is rodent toxicity (order of magnitude), not a human safe dose.")
                        }
                    }
                    .captionSecondary()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.xxs)
                }
            }
        }
    }

    /// The Stage-1 physicochemical descriptors, laid into the Chemistry grid as
    /// two-column rows. The `if let` guards keep them future-proof — a populated
    /// column just appears.
    @ViewBuilder
    private func physicochemicalRows(_ phys: Physicochemical?) -> some View {
        if let phys {
            if phys.logP != nil || phys.tpsa != nil {
                GridRow {
                    if let v = phys.logP { GridCell("LogP", chem(v)) } else { Color.clear }
                    if let v = phys.tpsa { GridCell("TPSA", "\(chem(v)) Å²") } else { Color.clear }
                }
            }
            if phys.hba != nil || phys.hbd != nil {
                GridRow {
                    if let v = phys.hba { GridCell("H-bond acceptors", "\(v)") } else { Color.clear }
                    if let v = phys.hbd { GridCell("H-bond donors", "\(v)") } else { Color.clear }
                }
            }
            if phys.meltingPointC != nil || phys.boilingPointC != nil {
                GridRow {
                    if let v = phys.meltingPointC { GridCell("Melting point", "\(chem(v)) °C") } else { Color.clear }
                    if let v = phys.boilingPointC { GridCell("Boiling point", "\(chem(v)) °C") } else { Color.clear }
                }
            }
            if phys.ld50OralMgPerKg != nil || phys.ld50DermalMgPerKg != nil {
                GridRow {
                    if let v = phys.ld50OralMgPerKg { GridCell("LD50 (oral, rodent)", "\(chem(v)) mg/kg") } else { Color.clear }
                    if let v = phys.ld50DermalMgPerKg { GridCell("LD50 (dermal, rodent)", "\(chem(v)) mg/kg") } else { Color.clear }
                }
            }
        }
    }

    private func chem(_ value: Double) -> String {
        chemNumber(value)
    }

    /// PubChem cell — a tappable link out to the curated chemistry record. Lives
    /// in Chemistry (not Info): it's a chemical identifier, same as the rest.
    ///
    /// A borderless `Button` (not a `Link`): a lone `Link` in a Form/List row gets
    /// promoted to a full-row tap target, so the whole Chemistry card would open
    /// PubChem. Borderless keeps the hit area to this one cell.
    private func pubChemCell(cid: Int, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("PubChem CID")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryLabel)
                    .textCase(.uppercase)
                HStack(spacing: 3) {
                    Text(verbatim: "\(cid)").font(.subheadline)
                    Image(systemName: "arrow.up.right").font(.caption2)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Theme.accent)
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
    }
}

enum SubstanceDetailScrollTarget: Hashable {
    case sources
}

/// Catalog sources and citations, with the fields each one supplied.
struct SourcesSection: View {
    let links: [DetailSourceLink]
    private let initiallyExpanded: Bool

    @State private var isExpanded: Bool

    init(links: [DetailSourceLink], initiallyExpanded: Bool) {
        self.links = links
        self.initiallyExpanded = initiallyExpanded
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        if !links.isEmpty {
            Section {
                DisclosureGroup("Sources", isExpanded: $isExpanded) {
                    ForEach(links) { link in
                        if let url = link.url {
                            Link(destination: url) {
                                SourceLedgerRow(link: link, linked: true)
                            }
                        } else {
                            SourceLedgerRow(link: link, linked: false)
                        }
                    }
                    Text("Each row lists what that source supplied here. Links open the source's own page. Always verify against the original.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .id(SubstanceDetailScrollTarget.sources)
                .onChange(of: initiallyExpanded) { _, expanded in
                    isExpanded = expanded
                }
            }
        }
    }
}

private struct SourceLedgerRow: View {
    let link: DetailSourceLink
    let linked: Bool

    @Environment(\.locale) private var locale

    private var providesSummary: String {
        link.provides.map { String(localized: $0.label) }
            .formatted(.list(type: .and).locale(locale))
    }

    var body: some View {
        // One column, two lines: the source, then what it supplied beneath it.
        // Keep it this way. Side-by-side columns have to divide a phone's width
        // between a name that can be a six-line paper title and a facet list
        // that can run to six terms, and whichever side loses the split wraps
        // into a ragged stack of one-word lines. Stacked, each gets the full
        // width and the facets read as a caption belonging to the name above.
        Group {
            if link.provides.isEmpty {
                nameColumn
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    nameColumn
                    providesText
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var nameColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            // `.firstTextBaseline`, not the default center: a citation title wraps
            // to five or six lines and a centered glyph then floats in the middle
            // of the block, reading as a bullet rather than a link marker.
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(link.label)
                    .font(.subheadline)
                    .foregroundStyle(linked ? Color.primary : Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                if linked {
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
            }
            if let license = link.license {
                // Verbatim: a license identifier is a proper noun and must not be
                // translated or reflowed into another form.
                Text(verbatim: license)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
    }

    private var providesText: some View {
        Text(providesSummary)
            .captionSecondary()
            .fixedSize(horizontal: false, vertical: true)
    }

    private var accessibilityLabel: Text {
        var parts = [link.label]
        if !link.provides.isEmpty {
            parts.append(String(localized: "supplies \(providesSummary)"))
        }
        if let license = link.license {
            parts.append(String(localized: "licensed \(license)"))
        }
        return Text(parts.joined(separator: ", "))
    }
}
