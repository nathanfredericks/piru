import SwiftUI

/// A full-width pill CTA — the app's one standard for prominent standalone
/// actions in empty states and at the end of lists.
/// `.prominent` is the accent-tinted primary (the system "Allow" pill);
/// `.neutral` is its plain counterpart for skip / not-now escape hatches.
/// The large system glass style gives the pill enough height so
/// the label always sits optically centered.
struct GlassPillButton: View {
    enum Prominence {
        case prominent
        case neutral
    }

    let title: LocalizedStringResource
    var prominence: Prominence = .prominent
    let action: () -> Void

    var body: some View {
        switch prominence {
        case .prominent:
            button
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(Theme.accent)
        case .neutral:
            button
                .buttonStyle(.glass)
                .controlSize(.large)
        }
    }

    private var button: some View {
        Button(action: action) {
            // The system supplies the prominent label color.
            label
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var label: some View {
        let text = Text(title).cardTitle()
        if prominence == .neutral {
            text.foregroundStyle(Theme.secondaryLabel)
        } else {
            text
        }
    }
}
