import AuthenticationServices
import CryptoKit
import Foundation
import Observation

@MainActor @Observable
final class SyncAccount {
    static let shared = SyncAccount()

    nonisolated struct Session: Codable, Equatable {
        let accountID: String
        let session: String
    }

    nonisolated struct Binding: Codable {
        let accountID: String
        let token: SyncSDKToken
        let anchorID: String
    }

    /// Replaces the device token while local cleanup is in progress.
    nonisolated struct DeletionReceipt: Codable {
        let deletedProfileID: String
        var localOnly: Bool?
        let grantID: String
        let accountID: String
    }

    nonisolated enum SavedBinding: Decodable {
        case active(Binding)
        case deleted(DeletionReceipt)

        init(from decoder: Decoder) throws {
            if let receipt = try? DeletionReceipt(from: decoder) {
                self = .deleted(receipt)
            } else {
                self = try .active(Binding(from: decoder))
            }
        }
    }

    nonisolated struct Connection: Sendable {
        let localProfileID: UUID
        let accountID: String
        let token: SyncSDKToken
        var profileID: String { token.profileID }
        var grantID: String { token.grantID }
        var signPrivate: String { token.signPrivate }
    }

    nonisolated struct KeySet {
        let epoch: Int
        let keys: SyncProfileKeys
        let grants: [SyncGrant]
    }

    struct Journal: Identifiable {
        let id: String
        let label: String
    }

    struct Access: Identifiable {
        let id: String
        let label: String
        let scope: String
        let isCurrent: Bool
        let isRevoked: Bool
    }

    enum Issue: LocalizedError {
        case signIn
        case challenge
        case changed
        case busy
        case bound
        case missing
        case recovery
        case duplicate
        case invalidLabel
        case needsEmptyProfile
        case storeUnavailable
        case pending

        var errorDescription: String? {
            switch self {
            case .signIn: String(localized: "Sign in to manage Journal Sync.")
            case .challenge: String(localized: "Refresh the sign-in request and try again.")
            case .changed: String(localized: "The linked journal changed. Refresh and try again.")
            case .busy: String(localized: "Wait for the current Journal Sync request to finish.")
            case .bound: String(localized: "This profile already has a linked journal.")
            case .missing: String(localized: "This journal has no active device credential.")
            case .recovery: String(localized: "Enter the recovery code saved for this journal.")
            case .duplicate: String(localized: "This journal is already linked to a profile on this device.")
            case .needsEmptyProfile: String(localized: "Choose an empty local profile or download into a new profile.")
            case .storeUnavailable: String(localized: "Piru could not verify this profile’s journal. Try again after the store is available.")
            case .invalidLabel: String(localized: "Enter a name of up to 120 characters.")
            case .pending: String(localized: "Retry the previous Journal Sync action to finish it.")
            }
        }
    }

    private(set) var signedIn: Bool
    var revision = 0
    @ObservationIgnored var busy = Set<UUID>()
    @ObservationIgnored var deleting = Set<UUID>()
    @ObservationIgnored var linking = Set<String>()
    @ObservationIgnored private var challenge: String?
    @ObservationIgnored private var issuedNonce: String?
    @ObservationIgnored let configuredRelay: Result<SyncTransport, Error>
    @ObservationIgnored let linkDirectory: ProfileDirectory?
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let device: any SyncAccountStorage
    @ObservationIgnored let codes: any SyncAccountStorage
    @ObservationIgnored let cloudCodes: any SyncAccountStorage

    init(
        relay: Result<SyncTransport, Error> = Result { try SyncTransport.configured() },
        defaults: UserDefaults = .standard,
        linkDirectory: ProfileDirectory? = nil,
        device: any SyncAccountStorage = SyncAccountKeychain(namespace: "device"),
        codes: any SyncAccountStorage = SyncAccountKeychain(namespace: "recovery"),
        cloudCodes: any SyncAccountStorage = SyncAccountKeychain(namespace: "recovery.icloud", synchronized: true),
    ) {
        self.device = device
        self.codes = codes
        self.cloudCodes = cloudCodes
        configuredRelay = relay
        self.defaults = defaults
        self.linkDirectory = linkDirectory
        let origin = (try? relay.get().base.absoluteString) ?? ""
        signedIn = defaults.string(forKey: "sync.account." + origin) != nil
    }

    var relay: SyncTransport { get throws { try configuredRelay.get() } }
    var origin: String { get throws { try relay.base.absoluteString } }
    var markersKey: String { get throws { try "sync.bindings." + origin } }

    func readSession() throws -> Session {
        guard let session = try device.read(Session.self, at: origin) else { throw Issue.signIn }
        return session
    }

    func reload() throws {
        let url = try origin
        let saved = try device.read(Session.self, at: url)
        defaults.set(saved?.accountID, forKey: "sync.account." + url)
        signedIn = saved != nil
        revision += 1
    }

    nonisolated struct Nonce: Decodable { let nonce: String }

    func prepareChallenge() async throws {
        let response: Nonce = try await relay.request("POST", ["auth", "nonce"])
        _ = try SyncWire.bytes(response.nonce, count: 32)
        challenge = response.nonce
    }

    func prepareSignIn(_ request: ASAuthorizationAppleIDRequest) throws {
        guard let challenge else { throw Issue.challenge }
        issuedNonce = challenge
        self.challenge = nil
        request.nonce = SHA256.hash(data: Data(challenge.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func finishSignIn(_ authorization: ASAuthorization) async throws {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let bytes = credential.identityToken, let jwt = String(data: bytes, encoding: .utf8),
              let nonce = issuedNonce else { throw Issue.challenge }
        issuedNonce = nil
        let response: Session = try await relay.request(
            "POST",
            ["auth", "apple"],
            body: JSONEncoder().encode(["identityToken": jwt, "nonce": nonce]),
        )
        try SyncWire.checkID(response.accountID)
        _ = try SyncWire.bytes(response.session, count: 32)
        guard busy.isEmpty else { throw Issue.busy }
        try device.write(response, at: origin)
        try reload()
    }

    /// Only an expired Apple session signs the account out. A disabled grant
    /// affects one profile and must leave other journals and pending edits intact.
    func accountRequest<T: Decodable & Sendable>(
        _ method: String, _ path: [String], session: Session, owner: String? = nil,
        requestID: String? = nil, body: Data? = nil,
    ) async throws -> T {
        do {
            return try await relay.request(
                method,
                path,
                bearer: session.session,
                owner: owner,
                requestID: requestID,
                body: body,
            )
        } catch SyncTransport.Failure.http(status: 401, code: let code) {
            if try readSession() == session {
                try device.remove(origin)
                try reload()
            }
            throw SyncTransport.Failure.http(status: 401, code: code)
        }
    }

    func signOut() throws {
        guard busy.isEmpty else { throw Issue.busy }
        try device.remove(origin)
        challenge = nil
        issuedNonce = nil
        try reload()
    }

    func isLinked(localProfileID: UUID) -> Bool { !deleting.contains(localProfileID) && isBound(localProfileID) }

    /// Reading this eligibility hint (including during launch) never opens Keychain.
    func isBound(_ id: UUID) -> Bool {
        _ = revision
        guard signedIn, let url = try? origin, let key = try? markersKey,
              let account = defaults.string(forKey: "sync.account." + url) else { return false }
        return (defaults.dictionary(forKey: key)?[id.uuidString] as? String)?.hasPrefix(account + "/") == true
    }

    func bindingKey(_ id: UUID) throws -> String { try origin + "/local/" + id.uuidString.lowercased() }

    func binding(_ id: UUID) throws -> Binding? {
        switch try device.read(SavedBinding.self, at: bindingKey(id)) {
        case let .active(binding): return binding
        case let .deleted(receipt): try finishDeletedJournal(id, receipt: receipt)
        case nil: break
        }
        return nil
    }

    func boundConnection(for localProfileID: UUID) throws -> Connection? {
        guard let b = try binding(localProfileID) else {
            try clearBindingMarker(localProfileID, origin: origin)
            return nil
        }
        let session = try readSession()
        guard session.accountID == b.accountID, try b.token.url == origin else { throw Issue.signIn }
        return Connection(localProfileID: localProfileID, accountID: b.accountID, token: b.token)
    }

    func deviceToken(localProfileID: UUID) throws -> SyncSDKToken {
        guard let c = try boundConnection(for: localProfileID) else { throw Issue.missing }
        return c.token
    }

    func ensureCurrent(_ c: Connection) throws {
        guard let now = try boundConnection(for: c.localProfileID), c.token == now.token else { throw Issue.changed }
    }

    func save(_ binding: Binding, local id: UUID) throws {
        let key = try markersKey
        var markers = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let marker = binding.accountID + "/" + binding.token.profileID
        guard !markers.contains(where: { $0.value == marker && $0.key != id.uuidString }) else { throw Issue.duplicate }
        // Publish the lookup hint first. A crash can leave a false positive,
        // which boundConnection safely rejects, never unfindable credentials.
        markers[id.uuidString] = marker
        defaults.set(markers, forKey: key)
        try device.write(binding, at: bindingKey(id))
        revision += 1
    }

    func refreshedKeys(for connection: Connection, epoch: Int? = nil) async throws -> KeySet {
        try ensureCurrent(connection)
        let result = try await material(connection.token, epoch: epoch)
        try ensureCurrent(connection)
        return result
    }

    func material(_ token: SyncSDKToken, epoch: Int? = nil) async throws -> KeySet {
        let page: SyncGrantsPage = try await relay.request(
            "GET",
            ["profiles", token.profileID, "grants"],
            query: epoch.map { [URLQueryItem(name: "epoch", value: String($0))] } ?? [],
            bearer: token.bearer,
        )
        guard page.epoch > 0, epoch == nil || epoch == page.epoch,
              let mine = page.grants.first(where: { $0.id == token.grantID }),
              try mine.boxPublic == (SyncWire.boxPublic(for: token.boxPrivate)),
              try mine.signPublic == (SyncWire.signPublic(for: token.signPrivate)),
              let wrapped = mine.wrapped else { throw Issue.missing }
        let keys = try SyncWire.unwrap(
            wrapped,
            profileID: token.profileID,
            grantID: token.grantID,
            epoch: page.epoch,
            boxPrivate: token.boxPrivate,
        )
        var seen = Set<String>()
        for grant in page.grants {
            guard seen.insert(grant.id).inserted else { throw SyncWireError.invalidEnvelope }
            _ = try Self.label(grant, profileID: token.profileID, keys: keys)
        }
        return KeySet(epoch: page.epoch, keys: keys, grants: page.grants)
    }

    func fetchChanges(for c: Connection, after: Int) async throws -> SyncChangesPage {
        try ensureCurrent(c)
        let page: SyncChangesPage = try await relay.request(
            "GET",
            ["profiles", c.profileID, "changes"],
            query: [URLQueryItem(name: "after", value: String(after))],
            bearer: c.token.bearer,
        )
        try ensureCurrent(c)
        return page
    }

    func postChange(_ envelope: SyncEnvelope, for c: Connection) async throws -> SyncReceipt {
        try ensureCurrent(c)
        guard envelope.profileID == c.profileID, envelope.grantID == c.grantID else { throw Issue.changed }
        let receipt: SyncReceipt = try await relay.request(
            "POST",
            ["profiles", c.profileID, "changes"],
            bearer: c.token.bearer,
            body: JSONEncoder().encode(envelope),
        )
        try ensureCurrent(c)
        return receipt
    }
}
