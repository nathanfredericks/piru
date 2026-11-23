import SwiftUI

/// The active profile's avatar at the leading edge of every tab root once a
/// second profile exists. Its menu lists everyone, the active one
/// checked, then Manage Profiles.
struct ProfileMenuButton: View {
    @Environment(\.profileDirectory) private var directory
    @Environment(\.appNavigator) private var navigator

    var body: some View {
        let active = directory.activeProfile
        Menu {
            Picker(selection: selection) {
                ForEach(directory.profiles) { profile in
                    Label {
                        Text(verbatim: profile.name)
                    } icon: {
                        ProfileAvatarImage.image(for: profile)
                    }
                    .tag(profile.id)
                }
            } label: {
                Text("Profiles")
            }
            .pickerStyle(.inline)
            Section {
                Button("Manage Profiles…") {
                    guard navigator.sheetStack.isEmpty else { return }
                    navigator.present(.profiles)
                }
            }
        } label: {
            ProfileGlassAvatar(profile: active)
        }
        .menuOrder(.fixed)
        .accessibilityLabel(Text("Profile: \(active.name)"))
        .accessibilityInputLabels([Text(verbatim: active.name), Text("Profile")])
    }

    private var selection: Binding<UUID> {
        Binding(
            get: { directory.activeProfileID },
            set: { id in Task(name: "Switch profile") { await ProfileSwitcher.switchTo(id) } },
        )
    }
}

/// ``ProfileMenuButton`` as a toolbar item of its own at the leading edge,
/// apart from the screen's trailing controls.
struct ProfileToolbarItem: ToolbarContent {
    var body: some ToolbarContent {
        if ProfileDirectory.shared.hasMultipleProfiles {
            ToolbarItem(placement: .platformTopBarLeading) {
                ProfileMenuButton()
            }
        }
    }
}

/// The avatar as a toolbar control: the photo, or the monogram or emoji on a
/// circle in the profile's color.
///
/// On a phone it fills the toolbar's own glass circle. The bar lays the label
/// out at its 36-point content height, so the avatar is drawn at the circle's
/// full 44 points and hangs over that slot by 4 points a side. Keep it inside
/// the bar's glass: given its own glass or a 44-point frame, the menu's close
/// animation clips it to 36 points and cuts off its top and bottom.
struct ProfileGlassAvatar: View {
    let profile: PiruProfile

    var body: some View {
        Group {
            if let image = profile.avatar.photo.flatMap(ProfilePhotoCache.image(named:)) {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.diameter, height: Self.diameter)
            } else {
                // An image, which the bar sizes as an icon; any other view
                // it pads into a wider capsule.
                ProfileAvatarImage.image(for: profile, diameter: Self.diameter)
            }
        }
        .clipShape(.circle)
        .padding(-Layout.overhang)
        .accessibilityHidden(true)
    }

    private enum Layout {
        /// How far the avatar reaches past the bar's 36-point content slot to
        /// fill its 44-point glass circle.
        static let overhang: CGFloat = 4
    }

    private static let diameter: CGFloat = 44
}
