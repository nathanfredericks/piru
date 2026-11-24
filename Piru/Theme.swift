import SwiftUI

/// The app's shared appearance tokens.
enum Theme {
    /// Brand accent and control tint. Rose in light mode and bright pink in dark mode.
    static var accent: Color {
        .accent
    }

    /// De-emphasized body text. Kept as an accessor over the catalog symbol
    /// for its ~600 call sites; gated by `ColorContrastTests`.
    ///
    /// Never swap this for the system `.secondary`: it measures 2.17:1 on the
    /// light card and fails WCAG AA.
    static var secondaryLabel: Color {
        .Text.secondary
    }

    /// Third-level text: the system `.tertiary`, raised to ``secondaryLabel``
    /// while Increase Contrast is on. For text a reader needs; a purely
    /// decorative separator can stay on `.tertiary`.
    static var tertiaryLabel: LegibleTertiary {
        LegibleTertiary(strong: .Text.secondary)
    }

    // MARK: - Surfaces

    // Colorsets, never `UIColor { traits }` closures: a closure branches on
    // `userInterfaceStyle` alone and cannot express the Any+HC / Dark+HC
    // variants.

    /// Page backdrop. True black in dark mode.
    static var background: Color {
        .Surface.background
    }

    /// Card / raised surface fill.
    static var cardBackground: Color {
        .Surface.card
    }

    /// Text-field and other input fills.
    static var inputBackground: Color {
        .Surface.input
    }

    // MARK: - Card geometry

    /// The card corner the app draws when nothing overrides it. `22` matches
    /// the system grouped-list / Library card rounding.
    static let cardCornerRadius: CGFloat = 22

    /// The standard card shape — concentric, so it inherits its radius from the
    /// enclosing container and only falls back to ``cardCornerRadius``.
    static var cardShape: ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(cardCornerRadius)), isUniform: true)
    }
}

struct ThemedBackground<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content.background(Theme.cardBackground, in: shape)
    }
}

struct CardBackground: View {
    var body: some View {
        Theme.cardBackground
    }
}

extension View {
    /// The app's standard card.
    ///
    /// The corner is **system-derived**, not fixed: `ConcentricRectangle` with
    /// `.concentric(minimum:)` inherits its radius from the enclosing container
    /// shape and only falls back to `minimum` when there is nothing to inherit
    /// from. Concentricity — nested shapes whose radii relate mathematically to
    /// their container — is a core principle of the system design language, and
    /// a fixed radius breaks it the moment a card is nested or the container
    /// rounding changes.
    ///
    /// Note: this does not also call `containerShape`, which requires an
    /// `InsettableShape` that `ConcentricRectangle` is not. Cards still derive
    /// from whatever container the system provides (sheet, screen, grouped
    /// list) but do not re-publish themselves as a container for their own
    /// children, so nested content needs an explicit radius.
    func themeCard(cornerRadius: CGFloat = Theme.cardCornerRadius) -> some View {
        modifier(ThemedBackground(
            shape: ConcentricRectangle(corners: .concentric(minimum: .fixed(cornerRadius)), isUniform: true),
        ))
    }

    /// Conditionally apply the card background — for rows that live inside a
    /// shared grouped container, where the container draws the background and the
    /// row should not.
    @ViewBuilder
    func themeCard(enabled: Bool, cornerRadius: CGFloat = Theme.cardCornerRadius) -> some View {
        if enabled {
            themeCard(cornerRadius: cornerRadius)
        } else {
            self
        }
    }

    func themeCapsule() -> some View {
        modifier(ThemedBackground(shape: Capsule()))
    }
}
