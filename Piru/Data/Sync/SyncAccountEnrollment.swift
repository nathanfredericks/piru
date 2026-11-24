import Foundation

extension SyncAccount {
    nonisolated struct Bootstrap: Encodable {
        let profileID: String
        let grant: SyncGrant
        let bearer: String
        let recoveryBox: String
    }

    /// Until both server commits and the local binding succeed, keep enough
    /// information to retry bootstrap/enrollment with the very same keys.
    nonisolated struct Enrollment: Codable {
        let accountID: String
        let device: SyncSDKToken
        let recoveryCode: String
        let bootstrap: Command?
        var linkTarget: LinkTarget?
    }

    func create(localProfileID id: UUID, label: String) async throws -> String {
        let name = try Self.normalizedLabel(label)
        guard busy.insert(id).inserted else { throw Issue.busy }
        defer { busy.remove(id) }
        let session = try readSession()
        let slot = try bindingKey(id) + "/enrollment"
        let stage: Enrollment
        if let saved = try device.read(Enrollment.self, at: slot) {
            guard saved.accountID == session.accountID, saved.bootstrap != nil else { throw Issue.pending }
            stage = saved
        } else {
            guard try binding(id) == nil else { throw Issue.bound }
            let profile = UUID().uuidString.lowercased()
            let url = try origin
            let anchor = Self.makeToken(url: url, profileID: profile)
            let root = Root(profileID: profile, accountID: session.accountID, epoch: 1, label: name, anchor: anchor)
            let code = "piru-r1." + SyncWire.newBearer()
            let keys = SyncProfileKeys.generate()
            let grant = try Self.makeGrant(anchor, scope: .owner, label: "recovery", epoch: 1, keys: keys)
            let create = try Bootstrap(
                profileID: profile,
                grant: grant,
                bearer: anchor.bearer,
                recoveryBox: Self.sealRoot(root, code: code),
            )
            let cmd = try Command(
                intent: "bootstrap",
                path: ["profiles"],
                body: JSONEncoder().encode(create),
                owner: nil,
                epoch: 1,
            )
            stage = Enrollment(
                accountID: session.accountID,
                device: Self.makeToken(url: url, profileID: profile),
                recoveryCode: code,
                bootstrap: cmd,
            )
            try device.write(stage, at: slot)
        }
        if let cmd = stage.bootstrap {
            let response: EpochReply = try await accountRequest(
                cmd.method,
                cmd.path,
                session: session,
                requestID: cmd.id,
                body: cmd.body,
            )
            guard response.epoch == 1 else { throw SyncTransport.Failure.malformed }
        }
        try await finishEnrollment(id, stage: stage, slot: slot, session: session)
        return stage.recoveryCode
    }

    func link(localProfileID id: UUID, profileID: String, recoveryCode: String?, requireActive: Bool = false) async throws {
        try SyncWire.checkID(profileID)
        guard let target = try linkTarget(id, requireActive: requireActive) else { throw Issue.needsEmptyProfile }
        guard linking.insert(profileID).inserted else { throw Issue.busy }
        defer { linking.remove(profileID) }
        guard busy.insert(id).inserted else { throw Issue.busy }
        defer { busy.remove(id) }
        let session = try readSession()
        let slot = try bindingKey(id) + "/enrollment"
        let stage: Enrollment
        if let saved = try device.read(Enrollment.self, at: slot) {
            guard saved.accountID == session.accountID, saved.bootstrap == nil, saved.device.profileID == profileID,
                  saved.linkTarget == nil || saved.linkTarget == target
            else { throw Issue.pending }
            stage = saved
        } else {
            guard try binding(id) == nil else { throw Issue.bound }
            let marker = session.accountID + "/" + profileID
            let markers = try defaults.dictionary(forKey: markersKey) as? [String: String] ?? [:]
            guard !markers.values.contains(marker) else { throw Issue.duplicate }
            let code: String
            if let recoveryCode {
                code = recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let stored = try findCode(profileID, session.accountID) {
                code = stored
            } else { throw Issue.recovery }
            // Validate before persisting: a mistyped code cannot strand a
            // resumable enrollment with permanently unreadable credentials.
            _ = try await recoveryRoot(profileID, session: session, code: code)
            stage = try Enrollment(
                accountID: session.accountID,
                device: Self.makeToken(url: origin, profileID: profileID),
                recoveryCode: code,
                bootstrap: nil,
                linkTarget: target,
            )
            try device.write(stage, at: slot)
        }
        try await finishEnrollment(id, stage: stage, slot: slot, session: session) {
            guard try self.linkTarget(id, requireActive: requireActive) == target else { throw Issue.needsEmptyProfile }
        }
    }

    private func finishEnrollment(
        _ id: UUID, stage: Enrollment, slot: String, session: Session, validateTarget: () throws -> Void = {},
    ) async throws {
        let root = try await recoveryRoot(stage.device.profileID, session: session, code: stage.recoveryCode)
        let commandSlot = slot + "/device/" + stage.device.grantID
        let intent = "enroll/" + stage.device.grantID
        try validateTarget()
        let (reply, cmd) = try await perform(slot: commandSlot, intent: intent, session: session, as: EpochReply.self) {
            try await self.enrollmentCommand(
                token: stage.device,
                admin: root.anchor,
                scope: .owner,
                label: String(localized: "Linked device"),
                intent: intent,
                reveal: false,
            )
        }
        guard reply.epoch == cmd.epoch, try readSession() == session else { throw Issue.changed }
        try validateTarget()
        try saveCode(stage.recoveryCode, profileID: stage.device.profileID, accountID: session.accountID)
        try save(Binding(accountID: session.accountID, token: stage.device, anchorID: root.anchor.grantID), local: id)
        try device.remove(slot)
        try device.remove(commandSlot)
    }
}
