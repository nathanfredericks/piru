import Foundation
import SwiftData

extension SyncAccount {
    func disconnect(_ id: UUID) throws {
        guard !busy.contains(id), !ProfileSync.shared.isSyncing(id) else { throw Issue.busy }
        try detach(id, origin: origin, erasingLocalJournal: false)
    }

    /// A local erase must also detach a signed-out account or a previously configured relay.
    func detachForLocalErase(_ id: UUID) throws {
        guard !busy.contains(id), !ProfileSync.shared.isSyncing(id) else { throw Issue.busy }
        let prefix = "sync.bindings."
        var origins = Set(defaults.dictionaryRepresentation().keys.compactMap { key -> String? in
            guard key.hasPrefix(prefix), defaults.dictionary(forKey: key)?[id.uuidString] != nil else { return nil }
            return String(key.dropFirst(prefix.count))
        })
        if let origin = try? origin { origins.insert(origin) }
        for origin in origins { try detach(id, origin: origin, erasingLocalJournal: true) }
        // A journal may retain assets even if it no longer has a binding.
        try SyncProjection.removeAvatarAssets(profileID: id, directory: linkDirectory ?? .shared)
    }

    private func detach(_ id: UUID, origin: String, erasingLocalJournal: Bool) throws {
        let path = origin + "/local/" + id.uuidString.lowercased()
        let enrollment = path + "/enrollment"
        if let saved = try device.read(SavedBinding.self, at: path) {
            let receipt: DeletionReceipt
            switch saved {
            case let .deleted(pending): receipt = pending
            case let .active(bound):
                let admin = path + "/admin/" + bound.accountID + "/" + bound.token.grantID
                // Keep a retryable cloud DELETE on ordinary disconnect. An explicit local
                // erase discards pending commands and never sends them to the relay.
                if !erasingLocalJournal, try device.read(Command.self, at: admin)?.intent == "delete" { throw Issue.pending }
                receipt = DeletionReceipt(deletedProfileID: bound.token.profileID, localOnly: true, grantID: bound.token.grantID, accountID: bound.accountID)
                try device.write(receipt, at: path)
            }
            try finishCleanup(id, receipt: receipt, origin: origin)
        } else {
            if let stage = try device.read(Enrollment.self, at: enrollment) {
                try device.remove(enrollment + "/device/" + stage.device.grantID)
                try device.remove(enrollment)
            }
            clearBindingMarker(id, origin: origin)
        }
    }

    func finishDeletedJournal(_ id: UUID, receipt: DeletionReceipt) throws {
        try finishCleanup(id, receipt: receipt, origin: origin)
    }

    private func finishCleanup(_ id: UUID, receipt: DeletionReceipt, origin: String) throws {
        let path = origin + "/local/" + id.uuidString.lowercased()
        try device.remove(path + "/admin/" + receipt.accountID + "/" + receipt.grantID)
        try device.remove(path + "/enrollment/device/" + receipt.grantID)
        try device.remove(path + "/enrollment")
        if receipt.localOnly != true {
            let recovery = origin + "/account/" + receipt.accountID + "/" + receipt.deletedProfileID
            try codes.remove(recovery)
            try cloudCodes.remove(recovery)
        }
        let directory = linkDirectory ?? ProfileDirectory.shared
        if let profile = directory.profiles.first(where: { $0.id == id }) {
            let context = try ModelContext(verifiedStore(for: profile, directory: directory))
            context.autosaveEnabled = false
            try context.delete(model: ProfileSyncDocument.self)
            try context.delete(model: ProfileSyncState.self)
            try context.save()
        }
        try SyncProjection.removeAvatarAssets(profileID: id, directory: directory)
        // Keep the nonsecret receipt reachable until every cleanup step succeeds.
        try device.remove(path)
        clearBindingMarker(id, origin: origin)
    }

    func clearBindingMarker(_ id: UUID, origin: String) {
        let key = "sync.bindings." + origin
        var markers = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        guard markers.removeValue(forKey: id.uuidString) != nil else { return }
        defaults.set(markers, forKey: key)
        revision += 1
    }
}
