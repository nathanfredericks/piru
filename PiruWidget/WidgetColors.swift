import SwiftUI

enum WidgetColors {
    static var accent: Color {
        .accent
    }

    static let backgroundGradientTop = Color(red: 0.06, green: 0.04, blue: 0.08)
    static let backgroundGradientBottom = Color(red: 0.10, green: 0.05, blue: 0.10)
}

struct WidgetBackground: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        if colorScheme == .dark {
            LinearGradient(
                colors: [
                    WidgetColors.backgroundGradientTop,
                    WidgetColors.backgroundGradientBottom,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing,
            )
        } else {
            Color(.systemBackground)
        }
    }
}
