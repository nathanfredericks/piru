import SwiftUI

/// Collapsed reference sections for mechanism, receptor literature, pharmacokinetics, and metabolism.
struct PharmacologySections: View {
    let substance: Substance
    let model: SubstanceDetailModel
    let onGlossary: (PharmacologyGlossarySheet.Topic) -> Void

    @State private var mechanismExpanded = false
    @State private var receptorLiteratureExpanded = false
    @State private var pharmacokineticsExpanded = false
    @State private var metabolismExpanded = false

    /// Metabolites whose formation runs through a polymorphic enzyme
    /// (CYP2D6/CYP2C19) *and* that carry real effect — the codeine → morphine,
    /// tramadol → M1, oxycodone → oxymorphone, atomoxetine, aripiprazole set.
    /// How much of a dose you convert is substantially genetic, which is the
    /// single most actionable fact on those drugs. It belongs in Metabolism as a
    /// calm line rather than as a headline (the review's editorial gate keeps
    /// divergent/ratio facts out of "Also Active"). Suppressed for any metabolite
    /// that already earns an "Also Active" card — its own card states it — so the
    /// note never appears twice on one screen.
    private var polymorphicConversionMetabolites: [ActiveMetabolite] {
        let carded = Set(model.durationChangingMetabolites(for: substance).map(\.id))
        return model.activeMetabolites.filter {
            $0.conversionVariesByGenetics && $0.isMateriallyActive && !carded.contains($0.id)
        }
    }

    var body: some View {
        let hero = model.pharmacologyHero(category: substance.category)

        Group {
            // The Pharmacology card: mechanism of action, with the monoamine slider
            // hero inline when the substance has a monoamine profile.
            if let moa = composedMechanism {
                CollapsibleSection(
                    "Pharmacology",
                    onInfo: { onGlossary(.mechanism) },
                    isExpanded: $mechanismExpanded,
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Load-bearing, not decoration. Every number below this line was
                        // measured on the molecule, and without the line the card reads as
                        // receptor data for a plant — which is how cannabis came to carry a
                        // CB1 Kᵢ in the first place.
                        if let ingredient = ActiveIngredient.resolve(substance.name) {
                            ActiveIngredientNote(
                                preparation: substance.displayTitle,
                                ingredient: ingredient,
                                accent: substance.category.color,
                            )
                        }
                        PharmacologyCard(
                            moa: moa,
                            monoamine: model.monoamineProfile,
                            category: substance.category,
                            hero: hero,
                            signature: model.classSignature,
                            onMonoamineInfo: { onGlossary(.monoamine) },
                        )
                        if let cascade = model.signalingCascade {
                            SignalingCascadeRow(cascade: cascade, accent: substance.category.color)
                        }
                    }
                }
            }

            // Suppressed for receptor-panel classes (opioid/benzo/dissociative): their hero already
            // carries the primary receptors, so a second table would duplicate it.
            if hero == nil, !model.visibleLiteratureBindings.isEmpty {
                CollapsibleSection(
                    "Receptor Literature",
                    onInfo: { onGlossary(.receptor) },
                    isExpanded: $receptorLiteratureExpanded,
                ) {
                    GroupedReceptorLiterature(rows: model.visibleLiteratureBindings, accent: substance.category.color)
                        .padding(.vertical, Spacing.xs)
                }
            }

            // Never put "Also Active" back in this cluster: it answers "is
            // something other than what I took producing this effect?", a fact
            // about the user's experience, so it lives open on the main screen
            // (``AlsoActiveSection``) while these cards start folded.

            if !model.pkRoutes.isEmpty {
                CollapsibleSection(
                    "Pharmacokinetics",
                    onInfo: { onGlossary(.pharmacokinetics) },
                    isExpanded: $pharmacokineticsExpanded,
                ) {
                    pharmacokineticsBody
                }
            }

            if !model.metabolismRows.isEmpty {
                CollapsibleSection(
                    "Metabolism",
                    isExpanded: $metabolismExpanded,
                ) {
                    metabolismBody
                }
            }
        }
    }

    /// Mechanism shown in the detail card, composed from three sources by
    /// precedence so real receptor data isn't hidden behind a generic template.
    /// This keeps substances with clear receptor data (mephedrone, the MMC
    /// cathinones) from showing a generic "Monoamine Modulator" mechanism.
    private var composedMechanism: MechanismOfAction? {
        MechanismOfActionDatabase.resolvedMechanism(
            dbMechanism: substance.mechanismOfAction,
            category: substance.category,
        )
    }

    /// Per-route PK (bioavailability/tmax/half-life) above the CYP metabolism
    /// pathways, each row carrying its own source/citation. Mirrors the Receptor
    /// Literature layout: dense, with a citation on every row.
    private var pharmacokineticsBody: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ForEach(model.pkRoutes) { row in
                PKRouteRow(hit: row.hit, studyCount: row.studyCount, accent: substance.category.color)
                if row.id != model.pkRoutes.last?.id { Divider() }
            }
            // What the numbers above mean at a given plasma level. Under the
            // routes rather than beside them: a threshold is about the drug, not
            // about how it got in.
            if !model.concentrationThresholds.isEmpty {
                Divider()
                ForEach(model.concentrationThresholds) { hit in
                    ConcentrationThresholdRow(hit: hit, accent: substance.category.color)
                    if hit.id != model.concentrationThresholds.last?.id { Divider() }
                }
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    /// The single row that should carry each curated divergent note. Several raw
    /// rows can name one metabolite family (MDMA lists MDA, S-MDA and R-MDA, all
    /// matching the MDA note), so the note is pinned to the first matching row —
    /// which in practice is the canonical one that also resolves to the library.
    private var divergentNoteRowIDs: Set<SubstanceStore.MetabolismHit.ID> {
        var seenNotes = Set<String>()
        var out = Set<SubstanceStore.MetabolismHit.ID>()
        for hit in model.metabolismRows {
            guard let metabolite = hit.metaboliteName,
                  let note = MetaboliteEditorial.divergentNote(parent: substance.name, metabolite: metabolite)
            else { continue }
            if seenNotes.insert(String(localized: note)).inserted { out.insert(hit.id) }
        }
        return out
    }

    /// The CYP/enzyme clearance pathways and their metabolites: its own section,
    /// sitting next to the grapefruit/smoking interaction banners (which act on
    /// these same enzymes).
    private var metabolismBody: some View {
        let noteRows = divergentNoteRowIDs
        return VStack(alignment: .leading, spacing: Spacing.md) {
            ForEach(model.metabolismRows) { hit in
                // The metabolite row folds its own curated "acts differently"
                // one-liner in (parentName keys ``MetaboliteEditorial``), deduped to
                // one row.
                MetabolismRow(
                    hit: hit,
                    accent: substance.category.color,
                    parentName: substance.name,
                    showsDivergentNote: noteRows.contains(hit.id),
                )
                if hit.id != model.metabolismRows.last?.id { Divider() }
            }
            // The "conversion is partly genetic" line stays as a section note — it's
            // a between-people fact, not tied to any single metabolite row.
            if !polymorphicConversionMetabolites.isEmpty {
                Divider()
                metabolismNote(
                    "How much of a dose becomes its active form is partly genetic. The same dose can produce noticeably more effect in some people than in others.",
                    systemImage: "person.2",
                )
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    /// A caption-weight note beneath the enzyme pathways — the divergent-metabolite
    /// sentences and the genetic-conversion line. Caption weight keeps it a note,
    /// not a headline; the leading glyph signals the axis (branch = different
    /// pharmacology, person-pair = between-people variability).
    private func metabolismNote(_ text: LocalizedStringResource, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(Theme.secondaryLabel)
                .accessibilityHidden(true)
            Text(text)
                .captionSecondary()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Cannabis acts through Δ9-THC — everything below is THC's." The one line that
/// keeps a preparation's pharmacology card from reading as receptor data for a
/// plant. See ``ActiveIngredient`` for why the mapping exists at all.
struct ActiveIngredientNote: View {
    let preparation: String
    let ingredient: String
    let accent: Color

    @Environment(\.appNavigator) private var navigator

    var body: some View {
        Button {
            navigator.push(.substance(name: ingredient))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Image(systemName: "arrow.trianglehead.branch")
                    .font(.caption2)
                    .accessibilityHidden(true)
                // Both names are proper nouns supplied at runtime, so the sentence
                // is a catalog key with two substituted names rather than three
                // concatenated `Text`s (`Text + Text` is deprecated).
                Text(
                    "\(preparation) acts through \(ingredient). The pharmacology below is \(ingredient)'s.",
                    comment: "Preparation borrowing its active ingredient's pharmacology",
                )
                .font(.caption)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(accent)
        }
        .buttonStyle(.plain)
        .padding(.bottom, Spacing.lg)
    }
}
