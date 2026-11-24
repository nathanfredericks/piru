import Foundation

extension SyncAccount {
    nonisolated struct EpochReply: Codable { let epoch: Int }
    nonisolated struct Deleted: Decodable { let deleted: Bool }

    /// Preserve the exact bytes and request ID before transport. A timeout can
    /// mean the Worker already committed the mutation.
    nonisolated struct Command: Codable {
        let intent: String
        let id: String
        let method: String
        let path: [String]
        let body: Data?
        let owner: String?
        let result: String?
        let epoch: Int?

        init(
            intent: String,
            path: [String],
            body: Data?,
            owner: String?,
            method: String = "POST",
            result: String? = nil,
            epoch: Int? = nil,
        ) {
            self.intent = intent
            id = UUID().uuidString.lowercased()
            self.method = method
            self.path = path
            self.body = body
            self.owner = owner
            self.result = result
            self.epoch = epoch
        }
    }

    func perform<T: Decodable & Sendable>(
        slot: String, intent: String, session: Session, as _: T.Type,
        make: () async throws -> Command,
    ) async throws -> (T, Command) {
        let command: Command
        if let saved = try device.read(Command.self, at: slot) {
            guard saved.intent == intent else { throw Issue.pending }
            command = saved
        } else {
            command = try await make()
            try device.write(command, at: slot)
        }
        guard try readSession() == session else { throw Issue.changed }
        do {
            let response: T = try await accountRequest(
                command.method,
                command.path,
                session: session,
                owner: command.owner,
                requestID: command.id,
                body: command.body,
            )
            return (response, command)
        } catch let SyncTransport.Failure.http(status, reason) {
            if status == 409 || (intent == "delete" && [400, 403, 404, 405].contains(status)) {
                // A rejected mutation has no commit to replay. Keep the binding
                // and recovery keys; the owner can retry or disconnect locally.
                try device.remove(slot)
            }
            throw SyncTransport.Failure.http(status: status, code: reason)
        }
    }

    nonisolated struct HistoricWrap: Codable { let epoch: Int; let wrapped: SyncWrappedKey }
    nonisolated struct GrantRequest: Encodable {
        let epoch: Int
        let grant: SyncGrant
        let bearer: String
        let history: [HistoricWrap]
    }

    func enrollmentCommand(
        token: SyncSDKToken,
        admin: SyncSDKToken,
        scope: SyncGrantScope,
        label: String,
        intent: String,
        reveal: Bool,
    ) async throws -> Command {
        let current = try await material(admin)
        let grant = try Self.makeGrant(token, scope: scope, label: label, epoch: current.epoch, keys: current.keys)
        var history: [HistoricWrap] = []
        for epoch in 1 ..< current.epoch {
            let historical = try await material(admin, epoch: epoch)
            let wrap = try SyncWire.wrap(
                historical.keys,
                profileID: token.profileID,
                grantID: token.grantID,
                epoch: epoch,
                boxPublic: grant.boxPublic,
            )
            history.append(HistoricWrap(epoch: epoch, wrapped: wrap))
        }
        let request = GrantRequest(epoch: current.epoch, grant: grant, bearer: token.bearer, history: history)
        return try Command(
            intent: intent,
            path: ["profiles", token.profileID, "grants"],
            body: JSONEncoder().encode(request),
            owner: admin.bearer,
            result: reveal ? token.encoded() : nil,
            epoch: current.epoch,
        )
    }

    func grants(for id: UUID) async throws -> [Access] {
        guard let c = try boundConnection(for: id), let b = try binding(id) else { throw Issue.missing }
        let set = try await refreshedKeys(for: c)
        return try set.grants.filter { $0.id != b.anchorID }.map {
            try Access(
                id: $0.id,
                label: Self.label($0, profileID: c.profileID, keys: set.keys),
                scope: $0.scope.rawValue,
                isCurrent: $0.id == c.grantID,
                isRevoked: $0.revoked == true,
            )
        }
    }

    func issueToken(for id: UUID, label: String, canWrite: Bool) async throws -> String {
        let name = try Self.normalizedLabel(label)
        guard busy.insert(id).inserted else { throw Issue.busy }
        defer { busy.remove(id) }
        let session = try readSession()
        let admin = try deviceToken(localProfileID: id)
        let slot = try adminSlot(id, session.accountID, admin.grantID)
        let scope: SyncGrantScope = canWrite ? .write : .read
        let intent = "issue/" + scope.rawValue + "/" + name
        let (reply, cmd) = try await perform(slot: slot, intent: intent, session: session, as: EpochReply.self) {
            let token = Self.makeToken(url: admin.url, profileID: admin.profileID)
            return try await self.enrollmentCommand(token: token, admin: admin, scope: scope, label: name, intent: intent, reveal: true)
        }
        guard let token = cmd.result, cmd.epoch == reply.epoch else { throw SyncTransport.Failure.malformed }
        try device.remove(slot)
        revision += 1
        return token
    }

    nonisolated struct Recipient: Encodable { let grantID: String; let wrapped: SyncWrappedKey }
    nonisolated struct Rotation: Encodable {
        let epoch: Int
        let revoke: [String]
        let wraps: [Recipient]
        let recoveryBox: String
    }

    func adminSlot(_ id: UUID, _ accountID: String, _ grantID: String) throws -> String {
        try bindingKey(id) + "/admin/" + accountID + "/" + grantID
    }

    func revoke(for id: UUID, grantID: String) async throws {
        try SyncWire.checkID(grantID)
        guard busy.insert(id).inserted else { throw Issue.busy }
        defer { busy.remove(id) }
        guard let c = try boundConnection(for: id), let b = try binding(id), grantID != c.grantID, grantID != b.anchorID
        else { throw Issue.changed }
        let session = try readSession()
        let slot = try adminSlot(id, session.accountID, c.grantID)
        let intent = "revoke/" + grantID
        let (reply, cmd) = try await perform(slot: slot, intent: intent, session: session, as: EpochReply.self) {
            let current = try await self.refreshedKeys(for: c)
            guard current.grants.contains(where: { $0.id == grantID }) else { throw Issue.changed }
            let next = try SyncProfileKeys(contentKey: SyncWire.random32(), indexKey: current.keys.indexKey)
            let epoch = current.epoch + 1
            let wraps = try current.grants.filter { $0.id != grantID && $0.revoked != true }.map {
                try Recipient(grantID: $0.id, wrapped: SyncWire.wrap(
                    next,
                    profileID: c.profileID,
                    grantID: $0.id,
                    epoch: epoch,
                    boxPublic: $0.boxPublic,
                ))
            }
            let code = try self.recoveryCode(for: id)
            let root = try await self.recoveryRoot(c.profileID, session: session, code: code)
            guard root.epoch == current.epoch, root.anchor.grantID == b.anchorID else { throw Issue.changed }
            let updated = Root(
                profileID: c.profileID,
                accountID: c.accountID,
                epoch: epoch,
                label: root.label,
                anchor: root.anchor,
            )
            let rotation = try Rotation(
                epoch: current.epoch,
                revoke: [grantID],
                wraps: wraps,
                recoveryBox: Self.sealRoot(updated, code: code),
            )
            return try Command(
                intent: intent,
                path: ["profiles", c.profileID, "rotate"],
                body: JSONEncoder().encode(rotation),
                owner: c.token.bearer,
                epoch: epoch,
            )
        }
        guard reply.epoch == cmd.epoch else { throw SyncTransport.Failure.malformed }
        try device.remove(slot)
        revision += 1
    }

    func deleteJournal(for id: UUID) async throws {
        guard !ProfileSync.shared.isSyncing(id), busy.insert(id).inserted else { throw Issue.busy }
        deleting.insert(id)
        defer {
            busy.remove(id)
            deleting.remove(id)
        }
        guard let saved = try device.read(SavedBinding.self, at: bindingKey(id)) else { throw Issue.missing }
        let bound: Binding
        switch saved {
        case let .active(binding): bound = binding
        case let .deleted(receipt): return try finishDeletedJournal(id, receipt: receipt)
        }
        let session = try readSession()
        let token = bound.token
        guard session.accountID == bound.accountID, try token.url == origin else { throw Issue.signIn }
        let slot = try adminSlot(id, session.accountID, token.grantID)
        let (result, _) = try await perform(slot: slot, intent: "delete", session: session, as: Deleted.self) {
            Command(intent: "delete", path: ["profiles", token.profileID], body: nil, owner: token.bearer, method: "DELETE")
        }
        guard result.deleted else { throw SyncTransport.Failure.malformed }
        // Until the acknowledgment is durable, retries use the original DELETE
        // receipt. Once durable, cleanup can finish offline, including after a lock.
        let receipt = DeletionReceipt(deletedProfileID: token.profileID, grantID: token.grantID, accountID: bound.accountID)
        try device.write(receipt, at: bindingKey(id))
        try finishDeletedJournal(id, receipt: receipt)
    }
}
