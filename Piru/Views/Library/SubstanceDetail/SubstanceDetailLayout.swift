import SwiftUI

struct SubstanceDetailLayout: View {
    let substance: Substance
    /// Threaded separately from `substance` so it survives the shell→full-record
    /// swap: `Substance` is `Equatable` on `id` alone, so diffing `substance`
    /// can't see the overview appear and SwiftUI would skip this whole layout —
    /// an `Equatable` `SubstanceOverview?` field the diff *can* see forces the
    /// re-render when the resolved record lands.
    let overview: SubstanceOverview?
    let howItWorks: SubstanceOverview?
    let model: SubstanceDetailModel
    let sourceLinks: [DetailSourceLink]
    let showsSources: Bool
    let routes: RouteResolution
    let routeSelection: Binding<RouteOfAdministration>
    let saltSelection: Binding<String?>
    let isomerSelection: Binding<String?>
    /// The product the page opened on, preselected in Branded formulations.
    let initialBrand: String?
    let historyEntries: [DoseEntry]
    let inventoryItems: [InventoryItem]
    let selectedSaltForm: String?
    /// The user's personal-override notes for this substance, if any.
    let personalNotes: String?
    let showAllEffects: Binding<Bool>
    let onGlossary: (PharmacologyGlossarySheet.Topic) -> Void

    var body: some View {
        SubstanceDetailHeader(substance: substance)
        SubstanceProseSection(title: "How It Works", prose: howItWorks, substance: substance)
        SafetySection(substance: substance, model: model)

        if overview?.text != howItWorks?.text {
            SubstanceProseSection(title: "Overview", prose: overview, substance: substance)
        }

        if !historyEntries.isEmpty {
            HistorySection(entries: historyEntries, model: model, defaultUnit: substance.defaultUnit)
            // A hormone with depot ester curves: the serum level those doses add
            // up to, straight from the Injection Levels tool.
            if let analyte = DepotLevels.analyte(forSubstanceUID: substance.substanceUID) {
                DepotLevelsSection(analyte: analyte)
            }
        }

        if substance.displayClass.showsDoseLadder {
            DoseDurationSection(
                routes: routes,
                routeSelection: routeSelection,
                saltSelection: saltSelection,
                isomerSelection: isomerSelection,
                provenance: model.provenance,
                model: model,
                initialBrand: initialBrand,
            )
        }

        WikiTimingSection(records: model.wikiTimings)

        // Effects — the dose dial and what's reported at each band. The dose
        // card above carries the same five tiers as a *grid*: same scale,
        // different instrument for a different question.
        if substance.displayClass.showsDoseLadder {
            EffectsSection(substance: substance, showAllEffects: showAllEffects)
        }

        InventoryStockSection(
            substanceName: substance.name,
            selectedSaltForm: selectedSaltForm,
            inventoryItems: inventoryItems,
        )

        // How Long It Stays — the benzodiazepine duration ladder, directly above
        // the pharmacology because it's the class differentiator a benzo reader
        // reaches for first. Self-hides outside the family.
        BenzoDurationSection(substance: substance, model: model)

        PharmacologySections(substance: substance, model: model, onGlossary: onGlossary)

        // What else it touches — hERG, bladder, taste receptors.
        OffTargetSection(substance: substance, model: model)

        // The antidepressant class explainer, self-hiding outside its family.
        DrugClassSection(substance: substance)

        // Metabolites doing some of the work.
        AlsoActiveSection(substance: substance, model: model, onGlossary: onGlossary)

        // What CYP2D6 does to this substance — present for a CYP2D6-major substrate.
        if let cyp2d6Info = model.cyp2d6Info {
            CYP2D6NoteSection(
                substanceName: substance.displayTitle,
                cyp2d6Info: cyp2d6Info,
            )
        }

        // The genes behind that note and the ones it does not cover — CYP3A4,
        // OPRM1, COMT — each with the study.
        PharmacogeneticsSection(substance: substance, model: model)

        // Pathway bias, receptor complexes, in-vivo imaging; self-hiding, and
        // present for only a small share of compounds.
        TargetEvidenceSection(substance: substance, model: model)

        // What the family shares. Above Safety because for a research chemical
        // with no data of its own this is most of what there is to read.
        ClassContextSection(model: model)

        // Peptide protocol/reconstitution (self-hides for non-peptides).
        SubstancePeptideSection(substance: substance)

        if let personalNotes, !personalNotes.trimmingCharacters(in: .whitespaces).isEmpty {
            Section("Your Notes") {
                Text(personalNotes)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        // Reference depth: identity, chemistry and sources, each a collapsed card.
        referenceDepth
    }

    @ViewBuilder private var referenceDepth: some View {
        // Identity — category, default route, and the full alias list, collapsed.
        // The header's alias chips only exist for a substance with curated
        // `popularAliases`, and the fallback deliberately refuses to dump the
        // raw alias list up there. Without this row most substances with
        // aliases could not show them at all, so identity keeps a home at
        // reference depth.
        InfoDisclosureSection(substance: substance, model: model)

        ChemistrySection(substance: substance, moleculeStructure: model.moleculeStructure)
        SourcesSection(links: sourceLinks, initiallyExpanded: showsSources)
    }
}

private struct SubstanceDetailHeader: View {
    let substance: Substance

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Popular aliases shown as chips before the overflow count.
    private var shownAliases: [String] {
        Array(substance.popularAliases.prefix(4))
    }

    /// Additional chemical/search names beyond the shown chips — the full alias
    /// index minus the curated ones already displayed.
    private var overflowCount: Int {
        let shown = Set(shownAliases.map { $0.lowercased() })
        let extras = substance.aliases.filter { alias in
            !shown.contains(alias.lowercased())
                && alias.caseInsensitiveCompare(substance.displayTitle) != .orderedSame
        }
        return extras.count
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.md) {
                // The formula drops under the chip at accessibility sizes,
                // where the two cannot share a row.
                let bylineLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.sm))
                    : AnyLayout(HStackLayout(spacing: Spacing.md))
                bylineLayout {
                    Text(substance.category.displayName)
                        .font(.subheadline.weight(.semibold))
                    if let formula = substance.formula {
                        Text(formula)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.secondaryLabel)
                            .lineLimit(1)
                    }
                }

                // Framing marker (prescription / research compound / no human
                // data), on its own line rather than beside the category chip:
                // its titles are phrases, and a third item in that row overflows
                // the header at large text sizes and in Chinese.
                if let kind = SubstanceStatusMarker.Kind.resolve(for: substance) {
                    SubstanceStatusMarker(kind: kind)
                }

                if !shownAliases.isEmpty {
                    FlowLayout(spacing: 7) {
                        ForEach(shownAliases, id: \.self) { alias in
                            Text(alias)
                                .font(.subheadline)
                                .padding(.horizontal, Spacing.lg)
                                .padding(.vertical, 5)
                                .background(Color.platformTertiarySystemFill, in: Capsule())
                        }
                        if overflowCount > 0 {
                            Text("+ \(overflowCount) chemical names", comment: "Alias overflow count")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryLabel)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(aliasAccessibilityLabel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            Text("Data from published literature, product labels, and community databases, provided as is and without warranty. Not medical advice.")
                .textCase(nil)
        }
    }

    private var aliasAccessibilityLabel: String {
        let names = shownAliases.joined(separator: ", ")
        if overflowCount > 0 {
            return String(localized: "Also known as \(names), and \(overflowCount) other names.")
        }
        return String(localized: "Also known as \(names).")
    }
}
