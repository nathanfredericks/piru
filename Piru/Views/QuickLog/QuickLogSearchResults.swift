import SwiftUI

/// One search hit: a recent card, a library substance, a custom one,
/// or a combination product.
enum QuickLogSearchResult: Identifiable {
    case recent(SubstanceCard)
    /// A library hit, carrying the alias the query matched — so a search for
    /// "Concerta" can say so instead of silently resolving to "Methylphenidate".
    case library(SubstanceMatch)
    case custom(Substance)
    /// A combination product (co-codamol): its own case because picking it
    /// stages one dose per component, not a single substance.
    case combination(CustomSubstanceEntry)

    var id: String {
        switch self {
        case let .recent(card): "recent|\(card.id)"
        case let .library(match): "library|\(match.substance.name.lowercased())"
        case let .custom(substance): "custom|\(substance.name.lowercased())"
        case let .combination(entry): "combination|\(entry.id.uuidString)"
        }
    }
}

/// Everything the tray needs to stage one hit — assembled by the row on tap.
struct QuickLogStagePayload {
    let substance: String
    let route: RouteOfAdministration
    let unit: String
    let amount: Double
    let tint: P3Color?
    let librarySubstance: Substance?
    /// The name the user actually named this dose by — the catalog alias their
    /// query matched ("Concerta", "Vyvanse"). `nil` when they searched the
    /// canonical name, so nothing is asserted that they didn't say.
    ///
    /// Never a lookup key: `substance` stays canonical and every resolve keeps
    /// going through it.
    var productName: String?
    /// The injectable ester the search matched ("Valerate"), for a dose staged from
    /// an ester alias ("Estradiol Valerate"). Stored on `saltForm`, not `productName`
    /// — the ester is a form facet, not a brand. `nil` everywhere else.
    var saltForm: String?
    /// By-volume drink metadata carried from a recent's chip, so a re-logged
    /// drink re-stages exactly (name, strength, volume — chip parity) instead
    /// of opening a blank drink draft. `nil` everywhere else.
    var volumeML: Double?
    var abv: Double?
    var drinkName: String?
    var emoji: String?
}

struct QuickLogSearchResults: View {
    let results: [QuickLogSearchResult]
    let onAdd: (QuickLogStagePayload) -> Void
    let onAddCombination: (CustomSubstanceEntry) -> Void

    var body: some View {
        ForEach(results) { result in
            Button {
                if case let .combination(product) = result {
                    onAddCombination(product)
                } else if let payload = result.payload {
                    onAdd(payload)
                }
            } label: {
                VStack(alignment: .leading) {
                    Text(verbatim: result.title)
                    if let detail = result.detail {
                        Text(verbatim: detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
        }
    }
}

extension QuickLogSearchResult {
    fileprivate var title: String {
        switch self {
        case let .recent(card): card.title ?? card.productName ?? card.substanceName
        case let .library(match): match.matchedAlias ?? match.substance.displayTitle
        case let .custom(substance): substance.displayTitle
        case let .combination(product): product.displayName ?? product.name
        }
    }

    fileprivate var detail: String? {
        switch self {
        case let .recent(card):
            guard let route = card.routes.first, let dose = route.doses.first else { return nil }
            return "\(dose.amount.doseFormatted) \(dose.unit.unitDisplay(for: dose.amount))"
        case let .library(match):
            return match.matchedAlias == nil ? nil : match.substance.displayTitle
        case .custom, .combination:
            return nil
        }
    }

    /// The stage payload for one hit. Recents prefill from their most recent
    /// chip; library hits from the reference dose for the default route.
    var payload: QuickLogStagePayload? {
        switch self {
        case let .recent(card):
            guard let group = card.routes.first, let chip = group.doses.first else { return nil }
            return Self.recentPayload(card: card, group: group, chip: chip)
        case let .library(match):
            // An ester alias ("Estradiol Valerate") rides on saltForm, not
            // productName — it's a form facet, not a brand.
            if let alias = match.matchedAlias, let ester = SubstanceLibrary.saltForm(for: alias) {
                return payload(for: match.substance, productName: nil, saltForm: ester)
            }
            return payload(for: match.substance, productName: match.matchedAlias)
        case let .custom(substance):
            return payload(for: substance, productName: nil)
        case .combination:
            // A combination has no single substance to stage; `add` hands it to
            // `onAddCombination`, which stages one row per component.
            return nil
        }
    }

    static func recentPayload(card: SubstanceCard, group: SubstanceGroup, chip: DoseChip) -> QuickLogStagePayload {
        let productName = group.stageProductName
        // The card's ester rides on saltForm — an "Estradiol Enanthate" card
        // re-stages Enanthate. A dose logged under a name that states the ester
        // ("Estradiol Enanthate" as its product or its substance, as imported
        // logs carry it) holds it only in the name, so read it off the name.
        let saltForm = group.saltForm ?? card.saltForm
            ?? productName.flatMap { SubstanceLibrary.saltForm(for: $0) }
            ?? SubstanceLibrary.saltForm(for: card.substanceName)
        return QuickLogStagePayload(
            substance: card.substanceName,
            route: group.route,
            unit: chip.unit,
            amount: chip.amount,
            tint: card.tint,
            librarySubstance: group.librarySubstance,
            productName: productName,
            saltForm: saltForm,
            volumeML: chip.volumeML,
            abv: chip.abv,
            drinkName: chip.drinkName,
            emoji: chip.emoji,
        )
    }

    private func payload(for substance: Substance, productName: String?, saltForm: String? = nil) -> QuickLogStagePayload {
        // An injectable ester ("Estradiol Valerate") stages on its declared route
        // (IM/SC from ester_pk), not the base substance's default (oral) — logging
        // a depot ester by mouth is meaningless.
        let named = NamedSubstance(substance: substance, productName: productName, saltForm: saltForm)
        let route = named.esterRoute ?? substance.defaultRoute
        let unit = substance.unit(for: route, saltForm: saltForm, isomer: nil)
        return QuickLogStagePayload(
            // Canonical, always — `substance` is the lookup key every downstream
            // resolve depends on. The user's word rides alongside in `productName`
            // and never becomes a key.
            substance: substance.name,
            route: route,
            unit: unit,
            amount: substance.referenceDose(route: route, unit: unit, saltForm: saltForm) ?? 0,
            tint: nil,
            librarySubstance: substance,
            productName: productName,
            saltForm: saltForm,
        )
    }
}
