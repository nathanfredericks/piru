import SwiftUI

private enum AboutPrivacyLinks {
    static let privacyPolicy = URL(string: "https://kagerou.glass/piru/privacy")!
    static let terms = URL(string: "https://kagerou.glass/piru/terms")!
    static let corrections = URL(string: "https://github.com/kageroumado/piru/issues")!
}

/// Where each kind of data lives and when it leaves the device, then the full
/// policy and the place to report a wrong fact.
struct AboutPrivacySection: View {
    var body: some View {
        Section {
            CaptionedRowLabel(
                title: "Your journal",
                systemImage: "book",
                caption: Text("Stored in the app on this device, and in any device or iCloud backup your settings make of it. Anyone who can unlock the device can read it."),
            )
            CaptionedRowLabel(
                title: "Optional Journal Sync",
                systemImage: "lock.icloud",
                caption: Text("If you turn on sync, Piru encrypts the selected profile’s records before upload. Only authorized devices and apps can decrypt them. The service can see which account synced, when, and how much data moved."),
            )
            CaptionedRowLabel(
                title: "Apple Health",
                systemImage: "heart.text.square",
                caption: Text("Connect Apple Health to see readings alongside your entries. Journal Sync excludes readings from Apple Health."),
            )
            CaptionedRowLabel(
                title: "Exports and backups",
                systemImage: "square.and.arrow.up",
                caption: Text("Created when you ask and saved where you choose. Exports are unencrypted unless you choose an encrypted backup."),
            )
            CaptionedRowLabel(
                title: "Apple Watch",
                systemImage: "applewatch",
                caption: Text("Your entries sync between your iPhone and a paired Apple Watch."),
            )
            Label("No ads, no analytics, no trackers.", systemImage: "hand.raised")

            Link(destination: AboutPrivacyLinks.terms) {
                Label("Terms of Use", systemImage: "arrow.up.right")
            }
            Link(destination: AboutPrivacyLinks.privacyPolicy) {
                Label("Privacy Policy", systemImage: "arrow.up.right")
            }
            Link(destination: AboutPrivacyLinks.corrections) {
                Label("Report a correction", systemImage: "arrow.up.right")
            }
        } header: {
            Text("Privacy")
        }
    }
}
