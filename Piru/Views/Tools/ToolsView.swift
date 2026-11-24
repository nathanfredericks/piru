import SwiftUI

/// A tool surfaced in the Tools hub. Each value is pushed as a full-screen
/// destination via `PushRoute.tool`. Kept `nonisolated`/`Codable` so it can ride
/// inside `PushRoute` (state restoration + potential deep links).
nonisolated enum Tool: String, Hashable, Codable, CaseIterable, Identifiable {
    case interactions
    case calculator
    case volumetric
    case recovery
    case pharma
    case ceiling
    case benzoEquivalence
    case opioidEquivalence
    case toleranceInfo
    case inventory
    case steadyState
    case injectionLevels
    case drugClasses
    /// Every subjective effect a note can name, grouped by rollup and defined.
    case effects
    /// The box scanner as a reference: point the camera at any medication box
    /// and open what the library knows about what is inside.
    case identify

    var id: String {
        rawValue
    }

    /// Row label and pushed-screen title.
    var name: LocalizedStringResource {
        switch self {
        case .interactions: "Interactions"
        case .calculator: "Half-Life Calculator"
        case .volumetric: "Solution Math"
        case .recovery: "Recovery Guide"
        case .pharma: "Pharma Search"
        case .ceiling: "Ceiling Effect"
        case .benzoEquivalence: "Diazepam Equivalence"
        case .opioidEquivalence: "Opioid MME"
        case .toleranceInfo: "How Modeled Tolerance Works"
        case .inventory: "Inventory"
        case .steadyState: "Steady State"
        case .injectionLevels: "Injection Levels"
        case .drugClasses: "Drug Classes"
        case .effects: "Effect Glossary"
        case .identify: "Identify a Box"
        }
    }

    /// One-line description shown under the name in the hub list.
    var subtitle: LocalizedStringResource {
        switch self {
        case .interactions: "Check how substances interact"
        case .calculator: "Estimate active levels over time"
        case .volumetric: "Concentration and solvent volume for a solution"
        case .recovery: "Comedown and aftercare tips"
        case .pharma: "Browse pharmacokinetics for every substance"
        case .ceiling: "When dose and exposure aren't proportional"
        case .benzoEquivalence: "Published benzodiazepine equivalence table"
        case .opioidEquivalence: "Published oral MME reference factors"
        case .toleranceInfo: "Why effects fade and how receptors recover"
        case .inventory: "Track how much you have on hand"
        case .steadyState: "Where a repeated dose settles, and when"
        case .injectionLevels: "Project hormone levels from injectable esters"
        case .drugClasses: "What the members of a family share"
        case .effects: "What each effect means, grouped by kind"
        case .identify: "Point at any medication box to see what's inside it"
        }
    }

    var icon: String {
        switch self {
        case .interactions: "exclamationmark.triangle"
        case .calculator: "hourglass"
        case .volumetric: "drop"
        case .recovery: "heart.text.square"
        case .pharma: "pills"
        case .ceiling: "chart.line.uptrend.xyaxis"
        case .benzoEquivalence: "moon.fill"
        case .opioidEquivalence: "cross.case"
        case .toleranceInfo: "chart.line.downtrend.xyaxis"
        case .inventory: "shippingbox"
        case .steadyState: "chart.line.flattrend.xyaxis"
        case .injectionLevels: "syringe"
        case .drugClasses: "square.stack.3d.up"
        case .effects: "text.book.closed"
        case .identify: "barcode.viewfinder"
        }
    }
}

/// The Tools hub opens from the Library toolbar.
///
/// Cards with inventory previews and safety-relevant
/// summaries (Interactions) render full-width. Simpler tools sit in a
/// two-column grid to reduce vertical scroll.
struct ToolsView: View {
    /// Tools rendered as half-width compact cards, in order (left-to-right,
    /// top-to-bottom). Education, Inventory, and Interactions have
    /// full-width cards above the grid.
    private let compactTools: [Tool] = [
        .identify,
        .calculator, .steadyState,
        .injectionLevels, .volumetric,
        .pharma,
        .benzoEquivalence, .opioidEquivalence,
    ]

    private let gridColumns = [
        GridItem(.flexible(), spacing: Spacing.xl),
        GridItem(.flexible(), spacing: Spacing.xl),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                InventorySummaryCard()
                InteractionsSummaryCard()
                EducationCard()

                LazyVGrid(columns: gridColumns, spacing: Spacing.xl) {
                    ForEach(compactTools) { tool in
                        CompactRouteCard(
                            icon: tool.icon,
                            title: Text(tool.name),
                            subtitle: Text(tool.subtitle),
                            route: .tool(tool),
                        )
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, Spacing.xs)
            .padding(.bottom, 80)
        }
        .piruPageBackground()
        .appNavigationBar("Tools")
    }
}
