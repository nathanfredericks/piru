import SwiftUI

struct JournalSyncTokens: View {
    let profile: PiruProfile
    @State private var action = JournalSyncAction()
    @State private var grants: [SyncAccount.Access]?

    var body: some View {
        JournalSyncList(title: "Access Tokens", action: action) {
            Section {
                if let grants {
                    let tokens = grants.filter { $0.scope != "owner" }
                    if tokens.isEmpty { ContentUnavailableView("No Access Tokens", systemImage: "key") }
                    ForEach(tokens, id: \.id) { grant in
                        JournalSyncGrantRow(grant: grant, profile: profile) { revoke(grant) }
                    }
                }
                if action.error != nil { Button("Try Again") { load() } }
            } header: {
                Text(verbatim: profile.name)
            }
            Section {
                NavigationLink {
                    JournalSyncNewToken(profile: profile)
                } label: {
                    Label("Create Access Token", systemImage: "plus")
                }
            } footer: {
                Text("Each token gives one app access to the entire synced profile for \(profile.name).")
            }
            if let devices = grants?.filter({ $0.scope == "owner" }), !devices.isEmpty {
                Section("Linked devices") {
                    ForEach(devices, id: \.id) { grant in
                        JournalSyncGrantRow(grant: grant, profile: profile) { revoke(grant) }
                    }
                }
            }
        }
        .onAppear { load() }
    }

    private func revoke(_ grant: SyncAccount.Access) {
        action.run {
            try await SyncAccount.shared.revoke(for: profile.id, grantID: grant.id)
            grants?.removeAll { $0.id == grant.id }
        }
    }

    private func load() {
        action.run {
            grants = try await SyncAccount.shared.grants(for: profile.id).filter {
                !$0.isRevoked
            }
        }
    }
}

private struct JournalSyncGrantRow: View {
    let grant: SyncAccount.Access
    let profile: PiruProfile
    let revoke: () -> Void
    @State private var confirming = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(verbatim: grant.label)
                Text(permission).captionSecondary()
                if grant.scope == "owner" {
                    Text(verbatim: String(grant.id.prefix(8)))
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.secondaryLabel)
                }
            }
        } icon: { Image(systemName: grant.scope == "owner" ? "iphone" : "key") }
            .accessibilityElement(children: .combine)
        if !grant.isCurrent {
            Button(role: .destructive) { confirming = true } label: {
                if grant.scope == "owner" { Text("Revoke Device…") } else { Text("Revoke Token…") }
            }
            .accessibilityLabel("Revoke \(grant.label)")
            .alert("Revoke \(grant.label)?", isPresented: $confirming) {
                Button("Revoke Access", role: .destructive, action: revoke)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Future changes to \(profile.name) will use a new encryption key. Previously downloaded records can still be read.")
            }
        }
    }

    private var permission: LocalizedStringKey {
        if grant.isCurrent { return "This device" }
        if grant.scope == "owner" { return "Owner" }
        return grant.scope == "write" ? "Read and write" : "Read only"
    }
}

private struct JournalSyncNewToken: View {
    let profile: PiruProfile
    @Environment(\.dismiss) private var dismiss
    @State private var action = JournalSyncAction()
    @State private var name = ""
    @State private var canWrite = false
    @State private var secret: String?

    var body: some View {
        JournalSyncList(title: secret == nil ? "New Token" : "Token Created", action: action) {
            if let secret {
                Section {
                    LabeledContent("Permission") {
                        if canWrite { Text("Read and write") } else { Text("Read only") }
                    }
                    LabeledContent("Profile", value: profile.name)
                } header: { Text(verbatim: trimmedName) }
                JournalSyncSecret(value: secret, recovery: false)
                Button("Done") { dismiss() }
            } else {
                Section { LabeledContent("Profile", value: profile.name) }
                Section("Token name") {
                    TextField("Token name", text: $name, prompt: Text("Weekly summary"))
                }
                Section {
                    Picker("Permission", selection: $canWrite) {
                        Text("Read only").tag(false)
                        Text("Read and write").tag(true)
                    }
                    .pickerStyle(.inline)
                } footer: {
                    if canWrite {
                        Text("This app can read, export, add, edit, and delete any synced record in \(profile.name).")
                    } else {
                        Text("This app can read and export every synced record in \(profile.name).")
                    }
                }
                Button("Create Token") {
                    action.run {
                        secret = try await SyncAccount.shared.issueToken(for: profile.id, label: trimmedName, canWrite: canWrite)
                    }
                }
                .disabled(trimmedName.isEmpty || trimmedName.count > 120)
            }
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}
