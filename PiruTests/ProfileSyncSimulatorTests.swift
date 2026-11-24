import Foundation
import SwiftData
import Testing
@testable import Piru

/// The local harness starts one test host per simulator and an independent SDK client.
/// Every run makes a new local profile. Ordinary test runs have no relay dependency.
@Suite("Encrypted profile sync across devices")
@MainActor
struct ProfileSyncSimulatorTests {
    private nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["PIRU_SYNC_RENDEZVOUS"] != nil }

    @Test(.enabled(if: enabled))
    func `synthetic journal`() async throws {
        let env = ProcessInfo.processInfo.environment
        let endpoint = try #require(env["PIRU_SYNC_RENDEZVOUS"].flatMap(URL.init(string:)))
        let role = try #require(env["PIRU_SYNC_ROLE"])
        let fixtures = SimulatorRendezvous(url: endpoint)
        let setup = try await fixtures.get("session")
        let service = try #require(setup["url"].flatMap(URL.init(string:)))
        let account = try SyncAccount(
            relay: .success(SyncTransport(url: service)),
            defaults: #require(UserDefaults(suiteName: UUID().uuidString)),
        )
        let session = try SyncAccount.Session(accountID: #require(setup["accountID"]), session: #require(setup["session"]))
        try account.device.write(session, at: account.origin)
        try account.reload()
        let directory = ProfileDirectory.shared
        let profile = try directory.addProfile(name: "Synthetic " + role)
        let container = try #require(directory.container(for: profile.id, writable: true))
        let sync = ProfileSync(account: account)
        func transfer() async throws {
            await sync.sync(profileID: profile.id, container: container)
            try #require(sync.issue == nil, "Sync failed: \(sync.issue ?? "")")
            #expect(sync.pending == 0)
        }
        func dose(_ context: ModelContext) throws -> DoseEntry {
            try #require(context.fetch(FetchDescriptor<DoseEntry>()).first)
        }
        if role == "A" {
            let code = try await account.create(localProfileID: profile.id, label: "Synthetic")
            let local = ModelContext(container)
            let entry = DoseEntry(substance: "Synthetic", amount: 100)
            entry.locationName = "LOCAL ONLY"
            local.insert(entry)
            try local.save()
            try await transfer()
            let token = try await account.issueToken(for: profile.id, label: "SDK", canWrite: true)
            try await fixtures.put("linked", [
                "cloud": account.deviceToken(localProfileID: profile.id).profileID,
                "code": code, "token": token, "dose": entry.id.uuidString.lowercased(),
            ])
            _ = try await fixtures.get("b-offline")
            _ = try await fixtures.get("sdk-open")
            let edit = ModelContext(container)
            let changed = try dose(edit)
            changed.amount = 0.2
            changed.unit = "g"
            try edit.save()
            try await transfer()
            try await fixtures.put("a-edit")
            _ = try await fixtures.get("b-edit")
            try await transfer()
            let read = ModelContext(container)
            let merged = try dose(read)
            #expect(merged.notes == "From B")
            #expect(merged.tags.contains("from-sdk"))
            #expect(merged.locationName == "LOCAL ONLY")
            _ = try await fixtures.get("sdk-merged")
            read.delete(merged)
            try read.save()
            try await transfer()
            try await fixtures.put("a-delete")
            _ = try await fixtures.get("b-deleted")
            try await transfer()
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<DoseEntry>()) == 0)
            _ = try await fixtures.get("sdk-deleted")
            _ = try await fixtures.get("b-staged")
            let grant = try SyncSDKToken.decode(token)
            try await account.revoke(for: profile.id, grantID: grant.grantID)
            try await fixtures.put("rotated")
            _ = try await fixtures.get("b-recovered")
            try await transfer()
            #expect(try dose(ModelContext(container)).notes == "Pending across rotation")
            try await fixtures.put("a-done")
        } else {
            let config = try await fixtures.get("linked")
            try await account.link(localProfileID: profile.id, profileID: #require(config["cloud"]), recoveryCode: #require(config["code"]))
            try await transfer()
            let edit = ModelContext(container)
            let changed = try dose(edit)
            #expect(changed.amount == 100)
            #expect(changed.locationName == nil)
            changed.notes = "From B"
            try edit.save()
            try await fixtures.put("b-offline")
            _ = try await fixtures.get("sdk-edit")
            try await transfer()
            let read = ModelContext(container)
            let merged = try dose(read)
            #expect(merged.amount == 0.2 && merged.unit == "g")
            #expect(merged.notes == "From B")
            #expect(merged.tags.contains("from-sdk"))
            #expect(merged.locationName == nil)
            merged.notes = "Offline during deletion"
            try read.save()
            try await fixtures.put("b-edit")
            _ = try await fixtures.get("a-delete")
            try await transfer()
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<DoseEntry>()) == 0)
            try await fixtures.put("b-deleted")
            let connection = try #require(try account.boundConnection(for: profile.id))
            let oldKeys = try await account.refreshedKeys(for: connection)
            let offline = ModelContext(container)
            let pending = DoseEntry(substance: "Synthetic", amount: 1, notes: "Pending across rotation")
            offline.insert(pending)
            try offline.save()
            let journal = try ProfileSyncJournal(cloudID: connection.profileID, profileID: profile.id, container: container)
            _ = try await journal.capture()
            let row = try #require(try journal.row(SyncRecordKey(kind: "dose", id: pending.id)))
            _ = try journal.sealPending(row, for: connection, material: oldKeys)
            try await fixtures.put("b-staged")
            _ = try await fixtures.get("rotated")
            try await transfer()
            try account.disconnect(profile.id)
            let recovered = try directory.addProfile(name: "Synthetic recovery")
            try await account.link(localProfileID: recovered.id, profileID: connection.profileID, recoveryCode: config["code"])
            let newStore = try #require(directory.container(for: recovered.id, writable: true))
            await sync.sync(profileID: recovered.id, container: newStore)
            try #require(sync.issue == nil)
            #expect(try dose(ModelContext(newStore)).notes == "Pending across rotation")
            try await fixtures.put("b-recovered")
        }
    }
}

private struct SimulatorRendezvous {
    let url: URL
    func get(_ name: String) async throws -> [String: String] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(240))
        while ContinuousClock.now < deadline {
            let (data, response) = try await URLSession.shared.data(from: url.appendingPathComponent(name))
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                return try JSONDecoder().decode([String: String].self, from: data)
            }
            try await Task.sleep(for: .milliseconds(350))
        }
        throw URLError(.timedOut)
    }

    func put(_ name: String, _ values: [String: String] = [:]) async throws {
        var request = URLRequest(url: url.appendingPathComponent(name))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(values)
        let (_, response) = try await URLSession.shared.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 200)
    }
}
