import AuthenticationServices
import SwiftUI

/// A single in-flight user action per screen. Failures leave the screen in place for retry.
@MainActor @Observable
final class JournalSyncAction {
    private(set) var busy = false
    var error: String?

    func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await action()
            } catch let failure as ASAuthorizationError where failure.code == .canceled {
                return
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct JournalSyncList<Rows: View>: View {
    let title: LocalizedStringKey
    var action: JournalSyncAction?
    @ViewBuilder var rows: Rows

    var body: some View {
        List {
            Group {
                rows
                if let error = action?.error {
                    Section { Label(error, systemImage: "exclamationmark.circle") }
                }
            }
            .listRowBackground(CardBackground())
        }
        .disabled(action?.busy == true)
        .toolbar {
            if action?.busy == true {
                ToolbarItem(placement: .topBarTrailing) { ProgressView() }
            }
        }
        .themedPage()
        .inlineNavigationTitle()
        .navigationTitle(title)
    }
}

struct JournalSyncView: View {
    let profile: PiruProfile

    private let account = SyncAccount.shared
    @State private var action = JournalSyncAction()
    @State private var loaded = false
    @State private var bound = false
    @State private var starting = false

    var body: some View {
        JournalSyncList(title: "Journal Sync", action: action) {
            if !loaded {
                if action.error != nil {
                    Button("Try Again") { reload() }
                    if account.signedIn {
                        Button("Sign Out") { action.run { try account.signOut() } }
                    }
                } else {
                    ProgressView()
                }
            } else if !account.signedIn {
                Section {
                    CaptionedRowLabel(
                        title: "On this iPhone", systemImage: "book.closed.fill",
                        caption: Text("Connect this profile to sync its journal across your devices."),
                    )
                    LabeledContent("Profile", value: profile.name)
                }
                Section {
                    JournalSyncSignIn(action: action)
                } footer: {
                    Text("After sign-in, choose the journal you want to connect.")
                }
            } else if bound {
                JournalSyncConnectedRows(profile: profile, action: action)
            } else {
                Section {
                    LabeledContent("Profile", value: profile.name)
                    Button("Create Cloud Journal", systemImage: "icloud.and.arrow.up") { starting = true }
                    NavigationLink("Link a Journal") { JournalSyncLink(selectedProfile: profile) }
                }
                Section {
                    Button("Sign Out") { action.run { try account.signOut() } }
                }
            }
        }
        .navigationDestination(isPresented: $starting) { JournalSyncConsent(profile: profile) }
        .task { reload() }
        .onChange(of: account.revision) { refreshBinding() }
    }

    private func reload() {
        do {
            try account.reload()
            refreshBinding()
        } catch {
            loaded = false
            action.error = error.localizedDescription
        }
    }

    private func refreshBinding() {
        do {
            bound = try account.signedIn && account.boundConnection(for: profile.id) != nil
            loaded = true
            action.error = nil
        } catch {
            loaded = false
            action.error = error.localizedDescription
        }
    }
}

private struct JournalSyncSignIn: View {
    let action: JournalSyncAction
    @Environment(\.colorScheme) private var scheme
    @State private var ready = false
    @State private var attempt = 0
    private let account = SyncAccount.shared

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            do {
                try account.prepareSignIn(request)
            } catch {
                ready = false
                action.error = error.localizedDescription
            }
        } onCompletion: { result in
            let prepared = ready
            ready = false
            action.run {
                defer { attempt += 1 }
                if prepared { try await account.finishSignIn(result.get()) }
            }
        }
        .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
        .disabled(!ready)
        .frame(minHeight: 48)
        .listRowInsets(EdgeInsets())
        .task(id: attempt) {
            do {
                try await account.prepareChallenge()
                ready = true
            } catch is CancellationError {
                return
            } catch {
                action.error = error.localizedDescription
            }
        }
        if !ready, action.error != nil {
            Button("Try Again") {
                action.error = nil
                attempt += 1
            }
        }
    }
}

private struct JournalSyncConnectedRows: View {
    let profile: PiruProfile
    let action: JournalSyncAction

    @Environment(\.profileDirectory) private var directory
    @State private var disconnecting = false
    private let sync = ProfileSync.shared

    var body: some View {
        Section {
            if let snapshot = sync.status(for: profile.id) {
                Label(status(snapshot), systemImage: snapshot.issue == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.icloud")
                LabeledContent("Profile", value: profile.name)
                if let date = snapshot.lastSync {
                    LabeledContent("Last synced") { Text(date, format: .dateTime.month().day().hour().minute()) }
                }
                if snapshot.pending > 0 { LabeledContent("Pending changes", value: snapshot.pending.formatted()) }
                if let issue = snapshot.issue { Text(verbatim: issue).captionSecondary() }
            } else {
                LabeledContent("Profile", value: profile.name)
                ProgressView()
            }
        }
        Section {
            Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                action.run {
                    guard let container = directory.container(for: profile.id, writable: true) else {
                        throw ProfileDirectory.DirectoryError.unknownProfile
                    }
                    await sync.sync(profileID: profile.id, container: container)
                }
            }
            .disabled(sync.isSyncing(profile.id))
            NavigationLink {
                JournalSyncList(title: "Sync History") {
                    if let snapshot = sync.status(for: profile.id) {
                        if snapshot.history.isEmpty {
                            ContentUnavailableView("No sync activity yet", systemImage: "clock.arrow.circlepath")
                        }
                        ForEach(Array(snapshot.history.enumerated()), id: \.offset) { item in
                            if ProfileSyncJournal.isMergeReference(item.element) {
                                NavigationLink {
                                    JournalSyncMergeView(reference: item.element, profileID: profile.id)
                                } label: {
                                    Label("Edits merged automatically", systemImage: "arrow.triangle.merge")
                                }
                            } else if let title = ProfileSyncEvent.title(for: item.element) {
                                Text(LocalizedStringKey(title.key))
                            } else {
                                Text(verbatim: item.element)
                            }
                        }
                    } else {
                        ProgressView()
                    }
                }
            } label: { Label("Sync History", systemImage: "clock.arrow.circlepath") }
            NavigationLink {
                JournalSyncTokens(profile: profile)
            } label: { Label("Access Tokens", systemImage: "key") }
        }
        Section {
            NavigationLink {
                JournalSyncCloudData(profile: profile)
            } label: { Label("Manage Cloud Data", systemImage: "icloud") }
            Button("Disconnect This iPhone", role: .destructive) { disconnecting = true }
                .disabled(sync.isSyncing(profile.id))
                .confirmationDialog("Disconnect this iPhone?", isPresented: $disconnecting, titleVisibility: .visible) {
                    Button("Disconnect", role: .destructive) {
                        action.run { try SyncAccount.shared.disconnect(profile.id) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your journal stays on this iPhone. Apps with access tokens can still use the cloud journal.")
                }
        }
    }

    private func status(_ snapshot: ProfileSync.Status) -> LocalizedStringKey {
        if snapshot.working { return "Syncing…" }
        if snapshot.issue != nil { return "Sync interrupted" }
        if snapshot.pending > 0 { return "Changes waiting to sync" }
        return snapshot.lastSync == nil ? "Ready to sync" : "Up to date"
    }
}

private struct JournalSyncCloudData: View {
    let profile: PiruProfile

    @Environment(\.dismiss) private var dismiss
    @State private var action = JournalSyncAction()
    @State private var deleting = false

    var body: some View {
        JournalSyncList(title: "Cloud Data", action: action) {
            Section {
                LabeledContent("Cloud journal", value: profile.name)
                NavigationLink("Recovery Code") {
                    JournalSyncRecovery(profileID: profile.id)
                }
                Button("Delete Cloud Journal", role: .destructive) { deleting = true }
                    .disabled(ProfileSync.shared.isSyncing(profile.id))
                    .confirmationDialog("Delete the cloud journal for \(profile.name)?", isPresented: $deleting, titleVisibility: .visible) {
                        Button("Delete Cloud Journal", role: .destructive) {
                            action.run {
                                try await SyncAccount.shared.deleteJournal(for: profile.id)
                                dismiss()
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Deleting the cloud journal disconnects its devices and revokes its access tokens. Local copies stay on each device.")
                    }
            }
        }
    }
}
