import SwiftUI
import UIKit

typealias PlatformImage = UIImage
typealias PlatformView = UIView

extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}

extension ImageRenderer {
    var platformImage: PlatformImage? {
        uiImage
    }
}

enum PlatformPasteboard {
    static func copy(_ string: String) {
        UIPasteboard.general.string = string
    }

    static func copy(image: UIImage) {
        UIPasteboard.general.image = image
    }

    static func copy(data: Data, type: String) {
        UIPasteboard.general.setData(data, forPasteboardType: type)
    }
}

enum PlatformHaptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func impact() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

func openPlatformSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
    }
}

func openNotificationSettings() {
    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
        UIApplication.shared.open(url)
    }
}

// MARK: - System Color Shims

extension Color {
    static var platformSystemBackground: Color {
        Color(.systemBackground)
    }

    static var platformSecondarySystemBackground: Color {
        Color(.secondarySystemBackground)
    }

    static var platformSecondarySystemGroupedBackground: Color {
        Color(.secondarySystemGroupedBackground)
    }

    static var platformSecondarySystemFill: Color {
        Color(.secondarySystemFill)
    }

    static var platformTertiarySystemFill: Color {
        Color(.tertiarySystemFill)
    }

    static var platformQuaternaryLabel: Color {
        Color(.quaternaryLabel)
    }

    static var platformTertiaryLabel: Color {
        Color(.tertiaryLabel)
    }
}

// MARK: - View Modifier Shims

extension View {
    func inlineNavigationTitle() -> some View {
        self.navigationBarTitleDisplayMode(.inline)
    }

    func largeNavigationTitle() -> some View {
        self.navigationBarTitleDisplayMode(.large)
    }

    /// A search field that stays in view. The automatic placement hides it
    /// until the list is pulled down, which reads as "there is no search here".
    func alwaysVisibleSearch(text: Binding<String>, prompt: Text) -> some View {
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
    }

    func insetGroupedListStyle() -> some View {
        self.listStyle(.insetGrouped)
    }

    func wheelPickerStyle() -> some View {
        self.pickerStyle(.wheel)
    }

    /// Swipeable pages whose index is drawn by the caller.
    func pagedTabViewStyle() -> some View {
        self.tabViewStyle(.page(indexDisplayMode: .never))
    }

    /// The shape a long-press lifts into the context-menu preview.
    func contextMenuPreviewShape(_ shape: some Shape) -> some View {
        self.contentShape(.contextMenuPreview, shape)
    }

    func decimalKeyboard() -> some View {
        self.keyboardType(.decimalPad)
    }

    func neverAutocapitalize() -> some View {
        self.textInputAutocapitalization(.never)
    }

    func wordsAutocapitalize() -> some View {
        self.textInputAutocapitalization(.words)
    }

    func permanentEditMode() -> some View {
        self.environment(\.editMode, .constant(.active))
    }

    func compactListSectionSpacing() -> some View {
        self.listSectionSpacing(16)
    }
}

// MARK: - Toolbar Placement Shims

extension ToolbarItemPlacement {
    static var platformTopBarTrailing: ToolbarItemPlacement {
        .topBarTrailing
    }

    static var platformTopBarLeading: ToolbarItemPlacement {
        .topBarLeading
    }
}
