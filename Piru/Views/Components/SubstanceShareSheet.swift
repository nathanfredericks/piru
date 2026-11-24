import SwiftUI
import UIKit

/// Preview, copy, or share a substance reference card.
struct SubstanceShareSheet: View {
    let substance: Substance
    let route: SubstanceRoute?

    @State private var currentImage: PlatformImage?
    @State private var imageFileURL: URL?
    @State private var imageSourceView: PlatformView?
    @State private var justCopied = false
    @State private var copiedResetTask: Task<Void, Never>?

    var body: some View {
        FittedShareSheet("Share Substance", estimatedHeight: 460) {
            VStack(spacing: Spacing.xxl) {
                imageCard
                actions
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.bottom, Spacing.xxl)
        }
        .task { renderImage() }
    }

    // MARK: image card

    private var imageCard: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.04))
                if let currentImage {
                    Image(platformImage: currentImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(Spacing.lg)
                        .overlay { ZoomSourceView { imageSourceView = $0 } }
                        .overlay(alignment: .bottomTrailing) {
                            Label("Tap to view", systemImage: "arrow.up.left.and.arrow.down.right")
                                .shareHintPill(inset: Spacing.xxl)
                        }
                        .onTapGesture { openViewer() }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(Text("View substance card"))
                } else {
                    ProgressView().tint(Theme.accent)
                }
            }
            .frame(height: 360)
        }
    }

    // MARK: actions

    private var actions: some View {
        HStack(spacing: Spacing.lg) {
            Button { copy() } label: {
                Label(justCopied ? "Copied" : "Copy", systemImage: justCopied ? "checkmark" : "doc.on.doc")
                    .sectionLabel()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(Theme.secondaryLabel)
            .disabled(currentImage == nil)

            Button { share() } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .sectionLabel()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(Theme.accent)
            .disabled(currentImage == nil)
        }
    }

    // MARK: rendering

    private func renderImage() {
        guard currentImage == nil else { return }
        let store = SubstanceStore.shared
        let molecule = substance.smiles != nil ? store.moleculeStructure(forSubstanceName: substance.name) : nil
        let card = SubstanceShareCard(
            substance: substance, route: route, molecule: molecule,
            reportedEffects: store.reportedEffects(forSubstanceName: substance.name),
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        currentImage = renderer.platformImage
        refreshFileURL()
    }

    /// Re-encode the current image to a temp file so QuickLook opens instantly.
    private func refreshFileURL() {
        guard let image = currentImage, let data = image.pngData() else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("piru-\(substance.name.replacingOccurrences(of: " ", with: "-")).png")
        try? data.write(to: url)
        imageFileURL = url
    }

    // MARK: actions impl

    private func openViewer() {
        if let imageFileURL {
            ImageQuickLook.present(url: imageFileURL, from: imageSourceView)
        }
    }

    private func copy() {
        guard let currentImage else { return }
        PlatformPasteboard.copy(image: currentImage)
        justCopied = true
        copiedResetTask?.cancel()
        copiedResetTask = Task(name: "Reset copied flash") {
            try? await Task.sleep(for: UITiming.copiedFlash)
            guard !Task.isCancelled else { return }
            justCopied = false
        }
    }

    private func share() {
        guard let currentImage else { return }
        // Include the app link so recipients get a tappable kagerou.glass/piru
        // alongside the image (where Piru's info lives).
        var items: [Any] = [currentImage]
        if let url = URL(string: "https://kagerou.glass/piru") { items.append(url) }
        ShareSheetPresenter.present(items)
    }
}
