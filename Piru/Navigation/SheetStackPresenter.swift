import SwiftUI

/// Presents each sheet on the content of the sheet immediately below it.
private struct SheetLayer: ViewModifier {
    @Bindable var navigator: AppNavigator
    let depth: Int

    func body(content: Content) -> some View {
        if depth >= AppNavigator.maxSheetDepth {
            content
        } else {
            content.sheet(item: route) { route in
                SheetRouteView(route: route, depth: depth)
                    .environment(\.appNavigator, navigator)
                    .id(AppLanguageModel.shared.localization)
                    .modifier(SheetLayer(navigator: navigator, depth: depth + 1))
            }
        }
    }

    private var route: Binding<SheetRoute?> {
        Binding(
            get: { navigator.sheetStack.indices.contains(depth) ? navigator.sheetStack[depth] : nil },
            set: { route in
                if route == nil { navigator.truncateSheetStack(to: depth) }
            },
        )
    }
}

extension View {
    func sheetStackPresenter(_ navigator: AppNavigator) -> some View {
        modifier(SheetLayer(navigator: navigator, depth: 0))
    }
}
