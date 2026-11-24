import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct JournalSyncConsent: View {
    let profile: PiruProfile

    @Environment(\.profileDirectory) private var directory
    @Environment(\.dismiss) private var dismiss
    @State private var action = JournalSyncAction()
    @State private var code: String?

    var body: some View {
        if let code {
            JournalSyncList(title: "Recovery Code") {
                JournalSyncSecret(value: code, recovery: true)
                Button("Done") { dismiss() }
            }
        } else {
            JournalSyncList(title: "Start Sync", action: action) {
                Section {
                    CaptionedRowLabel(
                        title: "Create Cloud Journal", systemImage: "icloud.and.arrow.up.fill",
                        caption: Text("Create an encrypted cloud journal for this profile."),
                    )
                    LabeledContent("From this iPhone", value: profile.name)
                }
                Section {
                    Label("Doses, sessions, and notes", systemImage: "book")
                    Label("Medications, schedules, and inventory", systemImage: "pills")
                    Label("Manually entered labs and body data", systemImage: "heart.text.square")
                    Label("Custom substances, presets, and shortcuts", systemImage: "slider.horizontal.3")
                    Label("Profile details, preferences, and favorites", systemImage: "person.crop.circle")
                } header: {
                    Text("Included in sync")
                } footer: {
                    Text("Only authorized devices and apps can decrypt the synced profile. Location fields, Apple Health readings, device settings, and paired people’s journals stay on your device.")
                }
                Button("Start Sync") {
                    action.run {
                        guard let container = directory.container(for: profile.id, writable: true) else {
                            throw ProfileDirectory.DirectoryError.unknownProfile
                        }
                        code = try await SyncAccount.shared.create(localProfileID: profile.id, label: profile.name)
                        await ProfileSync.shared.sync(profileID: profile.id, container: container)
                    }
                }
                .fontWeight(.semibold)
            }
        }
    }
}

struct JournalSyncLink: View {
    let selectedProfile: PiruProfile
    @State private var action = JournalSyncAction()
    @State private var journals: [SyncAccount.Journal]?

    var body: some View {
        JournalSyncList(title: "Link a Journal", action: action) {
            if let journals {
                if journals.isEmpty {
                    ContentUnavailableView("No cloud journals", systemImage: "icloud")
                }
                ForEach(journals, id: \.id) { journal in
                    NavigationLink {
                        JournalSyncDownload(journal: journal, selectedProfile: selectedProfile)
                    } label: {
                        Label(journal.label, systemImage: "icloud.and.arrow.down")
                    }
                }
            }
            if action.error != nil {
                Button("Try Again") { load() }
            }
        }
        .task { load() }
    }

    private func load() {
        action.run { journals = try await SyncAccount.shared.journals() }
    }
}

private struct JournalSyncDownload: View {
    let journal: SyncAccount.Journal
    let selectedProfile: PiruProfile

    @Environment(\.profileDirectory) private var directory
    @State private var action = JournalSyncAction()
    @State private var code = ""
    @State private var profileName = ""
    @State private var linked: PiruProfile?
    @State private var canLinkSelected = false

    var body: some View {
        JournalSyncList(title: "Link a Journal", action: action) {
            Section {
                LabeledContent("Cloud journal", value: journal.label)
                if let linked {
                    LabeledContent("Profile", value: linked.name)
                    Button("Open Profile") {
                        action.run { await ProfileSwitcher.switchTo(linked.id, directory: directory) }
                    }
                } else {
                    SecureField("Recovery code", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                }
            } footer: {
                if linked == nil {
                    Text("If your key is in iCloud Keychain, you can leave the recovery code blank.")
                }
            }
            if linked == nil {
                if canLinkSelected {
                    Section {
                        LabeledContent("Profile", value: selectedProfile.name)
                        Button("Link This Empty Profile") { linkSelected() }
                    }
                }
                Section {
                    TextField("New profile name", text: $profileName)
                    Button("Download as New Profile") { download() }
                        .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .task(id: selectedProfile.id) {
            if profileName.isEmpty { profileName = journal.label }
            do {
                canLinkSelected = try directory.activeProfileID == selectedProfile.id && SyncAccount.shared.isEmptyForLinking(selectedProfile.id)
            } catch {
                canLinkSelected = false
                action.error = error.localizedDescription
            }
        }
    }

    private func linkSelected() {
        action.run {
            let id = selectedProfile.id
            let account = SyncAccount.shared
            guard directory.activeProfileID == id else { throw SyncAccount.Issue.changed }
            guard try account.isEmptyForLinking(id) else {
                canLinkSelected = false
                throw SyncAccount.Issue.needsEmptyProfile
            }
            let recovery = code.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try await account.link(localProfileID: id, profileID: journal.id, recoveryCode: recovery.isEmpty ? nil : recovery, requireActive: true)
            } catch SyncAccount.Issue.needsEmptyProfile {
                canLinkSelected = false
                throw SyncAccount.Issue.needsEmptyProfile
            }
            code = ""
            guard directory.activeProfileID == id else { return }
            linked = selectedProfile
            await ProfileSync.shared.sync(profileID: id, container: directory.activeContainer)
        }
    }

    private func download() {
        action.run {
            let account = SyncAccount.shared
            guard directory.activeProfileID == selectedProfile.id else { throw SyncAccount.Issue.changed }
            let reservation = "sync.download." + journal.id
            let defaults = UserDefaults.standard
            for profile in directory.profiles where account.isLinked(localProfileID: profile.id) {
                if try account.boundConnection(for: profile.id)?.profileID == journal.id {
                    defaults.removeObject(forKey: reservation)
                    linked = profile
                    code = ""
                    return
                }
            }
            let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
            var profile = PiruProfile.new(name: name, avatar: .monogram(for: name), color: .next(after: directory.profiles.map(\.color)))
            // Account enrollment retries are keyed by local UUID, including after a lost response or a relaunch.
            if let saved = defaults.string(forKey: reservation).flatMap(UUID.init(uuidString:)),
               directory.profile(id: saved) == nil {
                profile = profile.reidentified(as: saved, asOwner: false)
            }
            defaults.set(profile.id.uuidString.lowercased(), forKey: reservation)
            if let binding = try account.boundConnection(for: profile.id) {
                guard binding.profileID == journal.id else { throw SyncAccount.Issue.changed }
            } else {
                let recovery = code.trimmingCharacters(in: .whitespacesAndNewlines)
                try await account.link(localProfileID: profile.id, profileID: journal.id, recoveryCode: recovery.isEmpty ? nil : recovery)
            }
            code = ""
            guard directory.profile(id: profile.id) == nil else { throw SyncAccount.Issue.changed }
            try directory.restoreProfile(profile, as: profile.id, takingDetails: false)
            defaults.removeObject(forKey: reservation)
            linked = profile
            guard directory.activeProfileID == selectedProfile.id else { return }
            await ProfileSwitcher.switchTo(profile.id, directory: directory)
            guard directory.activeProfileID == profile.id else { return }
            await ProfileSync.shared.sync(profileID: profile.id, container: directory.activeContainer)
        }
    }
}

struct JournalSyncRecovery: View {
    let profileID: UUID
    @State private var action = JournalSyncAction()
    @State private var code: String?

    var body: some View {
        JournalSyncList(title: "Recovery Code", action: action) {
            if let code {
                JournalSyncSecret(value: code, recovery: true)
            } else {
                Button("Show Recovery Code") {
                    action.run { code = try SyncAccount.shared.recoveryCode(for: profileID) }
                }
            }
        }
    }
}

struct JournalSyncSecret: View {
    let value: String
    let recovery: Bool
    @State private var copied = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section {
            Text(verbatim: value)
                .font(.body.monospaced())
                .privacySensitive()
                .redacted(reason: scenePhase == .active ? [] : .privacy)
                .accessibilityHidden(scenePhase != .active)
        } header: {
            if recovery { Text("Your recovery code") } else { Text("Your token") }
        } footer: {
            if recovery {
                Text("Save this code somewhere private. You can use it to open the journal on another device.")
            } else {
                Text("Copy the token before closing this screen. Anyone who has it can use its permissions.")
            }
        }
        Button {
            UIPasteboard.general.setItems(
                [[UTType.utf8PlainText.identifier: value]],
                options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(120)],
            )
            copied = true
            AccessibilityNotification.Announcement(String(localized: "Copied")).post()
        } label: {
            if copied {
                Label("Copied", systemImage: "checkmark")
            } else if recovery {
                Label("Copy Recovery Code", systemImage: "document.on.document")
            } else {
                Label("Copy Token", systemImage: "document.on.document")
            }
        }
    }
}
