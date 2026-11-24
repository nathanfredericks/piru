import Foundation
import SwiftData

/// Checkpoints belong to the same journal store as the records they describe.
@Model
final class ProfileSyncState {
    @Attribute(.unique) var cloudID: String
    var cursor: Int = 0
    var bootstrapped: Bool = false
    var inventoryDirty: Bool = false
    var historyToken: Data?
    var identityBackfillTransaction: Int64?
    var lastSync: Date?
    var events: [String] = []

    init(cloudID: String) {
        self.cloudID = cloudID
    }
}

/// A pending document is its own outbox item. Keep the exact signed bytes
/// until acknowledged so a dropped HTTP response can be retried verbatim.
@Model
final class ProfileSyncDocument {
    #Unique<ProfileSyncDocument>([\.cloudID, \.kind, \.recordID])
    #Index<ProfileSyncDocument>([\.cloudID, \.pending])
    var cloudID: String
    var kind: String
    var recordID: String
    @Attribute(.externalStorage) var document: Data
    var scanID: UUID?
    var fields: Data?
    var pending: Bool
    var exceedsRelayLimit: Bool = false
    var operationID: String
    @Attribute(.externalStorage) var envelope: Data?

    init(cloudID: String, kind: String, recordID: String, document: Data, fields: Data?, pending: Bool) {
        self.cloudID = cloudID
        self.kind = kind
        self.recordID = recordID
        self.document = document
        self.fields = fields
        self.pending = pending
        self.operationID = UUID().uuidString.lowercased()
    }
}
