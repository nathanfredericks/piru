import SwiftUI

struct SafetySection: View {
    let substance: Substance
    let model: SubstanceDetailModel

    var body: some View {
        Section {
            RouteLink(.tool(.interactions), disclosure: true) {
                Label("Check how substances interact", systemImage: "exclamationmark.triangle")
            }

            if let warning = model.valvularWarning {
                ValvularWarningBanner(warning: warning, accent: substance.category.color)
            }

            if !substance.combinations.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("Combinations").font(.headline)
                    CombinationsList(combinations: substance.combinations)
                }
            }

            if let caution = model.contraceptionCaution {
                ContraceptionCautionBanner(inducer: caution)
            }

            ForEach(model.metabolicEducation) { effect in
                MetabolicModulationBanner(effect: effect)
            }

            if !model.pkInteractions.isEmpty {
                DisclosureGroup("Measured Interactions") {
                    ForEach(model.pkInteractions) { hit in
                        PKInteractionRow(hit: hit)
                            .padding(.vertical, Spacing.xs)
                    }
                }
            }
        } header: {
            Text("Interactions")
        }

        if substance.displayClass.showsDoseLadder {
            additionalSafety
        }
    }

    @ViewBuilder private var additionalSafety: some View {
        if substance.waterHeat != nil || !substance.misconceptions.isEmpty {
            Section("Safety") {
                if let water = substance.waterHeat {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        Text("Water & heat").font(.headline)
                        WaterHeatCard(guidance: water)
                    }
                }
                if !substance.misconceptions.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        Text("Common misconceptions").font(.headline)
                        MythBustList(misconceptions: substance.misconceptions, accent: substance.category.color)
                    }
                }
            }
        }
    }
}
