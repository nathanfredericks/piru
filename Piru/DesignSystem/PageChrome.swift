import SwiftUI

extension View {
    /// The app's page backdrop for a `List` or `Form`: drop the system's own
    /// scroll background and paint ``Theme/background`` behind it, so a grouped
    /// list reaches true black in dark mode like every other surface.
    func themedPage() -> some View {
        scrollContentBackground(.hidden)
            .skinBackdrop()
    }

    /// Bottom room so a pushed screen's last row (a Delete button, say)
    /// scrolls clear of the tab bar's session accessory. The system insets
    /// scroll content for the tab bar itself; the accessory floats above it
    /// uncounted, so this reserves its control row
    /// (``IconSize/touchTarget``, the accessory's expanded control size) and
    /// the gap above it.
    func tabAccessoryClearance() -> some View {
        contentMargins(.bottom, IconSize.touchTarget + Spacing.xxxl, for: .scrollContent)
    }
}
