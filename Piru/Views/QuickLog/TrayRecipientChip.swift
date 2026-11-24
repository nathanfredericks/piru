import SwiftUI

struct TrayRecipientRow: View {
    @Bindable var model: DoseTrayModel
    @Environment(\.profileDirectory) private var directory

    var body: some View {
        if directory.hasMultipleProfiles || model.recipientID != nil {
            Picker("Log For", selection: selection) {
                if let id = model.recipientID, directory.profile(id: id) == nil {
                    Text("Profile unavailable").tag(id)
                }
                ForEach(directory.profiles) { profile in
                    Text(verbatim: profile.name).tag(profile.id)
                }
            }
        }
    }

    private var selection: Binding<UUID> {
        Binding(
            get: { model.recipientID ?? directory.activeProfileID },
            set: { model.recipientID = $0 == directory.activeProfileID ? nil : $0 },
        )
    }
}
