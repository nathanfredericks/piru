import CryptoKit
import Foundation

extension SyncProjection {
    static let metadataKind = "profileMetadata"
    static let avatarAssetKind = "profileAvatarAsset"

    /// File type belongs to the reference. Identical bytes always have a single asset document.
    private struct Avatar: Codable {
        let kind: ProfileAvatar.Kind
        let text: String
        let assetID: String?
        let photoExtension: String?
    }

    private struct Photo {
        let key: SyncRecordKey
        let ext: String
    }

    private final class CachedAsset {
        let key: SyncRecordKey
        let size: Int
        let modified: Date?
        let fields: SyncFields

        init(key: SyncRecordKey, size: Int, modified: Date?, fields: SyncFields) {
            self.key = key
            self.size = size
            self.modified = modified
            self.fields = fields
        }
    }

    private static let avatarCache: NSCache<NSURL, CachedAsset> = {
        let cache = NSCache<NSURL, CachedAsset>()
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    private static let extensions = ["heic", "jpg", "jpeg", "png"]

    private static func archive(profileID: UUID, directory: ProfileDirectory) -> URL {
        directory.containerURL.appending(path: "profile-sync-avatars", directoryHint: .isDirectory)
            .appending(path: profileID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    /// Called when the local binding's cached sync data is erased. Displayed photos belong to the registry.
    static func removeAvatarAssets(profileID: UUID, directory: ProfileDirectory) throws {
        let url = archive(profileID: profileID, directory: directory)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        avatarCache.removeAllObjects()
    }

    private static func validateAssetKey(_ key: SyncRecordKey) throws {
        guard key.kind == avatarAssetKind, let id = UUID(uuidString: key.recordID),
              id.uuidString.lowercased() == key.recordID, id.uuid.6 >> 4 == 8,
              id.uuid.8 >> 6 == 2 else { throw SyncProjectionError.invalidKey(key) }
    }

    private static func key(for bytes: Data) -> SyncRecordKey {
        SyncRecordKey(kind: avatarAssetKind, id: hashUUID(SHA256.hash(data: bytes)))
    }

    private static func store(_ bytes: Data, at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == bytes else { throw SyncProjectionError.invalidField("bytes") }
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic)
        }
    }

    private static func readAsset(at url: URL) throws -> CachedAsset {
        let stat = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = stat.fileSize, (1 ... PiruProfilesSection.maxPhotoBytes).contains(size) else {
            throw SyncProjectionError.missingPhoto
        }
        if let cached = avatarCache.object(forKey: url as NSURL),
           cached.modified == stat.contentModificationDate, cached.size == size { return cached }
        let bytes = try Data(contentsOf: url)
        guard bytes.count == size else { throw SyncProjectionError.missingPhoto }
        let cached = try CachedAsset(
            key: key(for: bytes),
            size: size,
            modified: stat.contentModificationDate,
            fields: ["bytes": SyncJSON.encode(SyncWire.base64URL(bytes))],
        )
        avatarCache.setObject(cached, forKey: url as NSURL, cost: cached.fields["bytes"]?.utf8.count ?? size)
        return cached
    }

    static func avatarAssetFields(_ key: SyncRecordKey, profileID: UUID, directory: ProfileDirectory) throws -> SyncFields? {
        try validateAssetKey(key)
        guard directory.profiles.contains(where: { $0.id == profileID }) else { throw SyncProjectionError.unknownProfile(profileID) }
        let url = archive(profileID: profileID, directory: directory).appending(path: key.recordID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let cached = try readAsset(at: url)
        guard cached.key == key else { throw SyncProjectionError.invalidField("bytes") }
        return cached.fields
    }

    private static func filename(_ photo: Photo, profileID: UUID, pending: Bool) -> String {
        let prefix = pending ? "pending-avatar" : "avatar"
        return "\(prefix)-\(profileID.uuidString.lowercased())-\(photo.key.recordID).\(photo.ext)"
    }

    private static func selectedPhoto(_ profile: PiruProfile, directory: ProfileDirectory) throws -> Photo? {
        guard let name = profile.avatar.photo else { return nil }
        guard !name.isEmpty, !name.contains("/") else { throw SyncProjectionError.missingPhoto }
        let url = ProfilePhotoStore.url(named: name, in: directory.containerURL)
        let ext = url.pathExtension.lowercased()
        guard extensions.contains(ext) else { throw SyncProjectionError.invalidField("photoExtension") }
        let prefix = "pending-avatar-\(profile.id.uuidString.lowercased())-"
        if name.hasPrefix(prefix) {
            let id = String(url.deletingPathExtension().lastPathComponent.dropFirst(prefix.count))
            let key = SyncRecordKey(kind: avatarAssetKind, recordID: id)
            try validateAssetKey(key)
            return Photo(key: key, ext: ext)
        }
        let cached = try readAsset(at: url)
        let archived = archive(profileID: profile.id, directory: directory).appending(path: cached.key.recordID)
        if !FileManager.default.fileExists(atPath: archived.path) {
            try FileManager.default.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Both paths are in the same app group. The picker creates immutable files and the sweeper unlinks them.
            try FileManager.default.linkItem(at: url, to: archived)
        }
        return Photo(key: cached.key, ext: ext)
    }

    static func validateMetadataKey(_ key: SyncRecordKey) throws {
        guard key == SyncRecordKey(kind: metadataKind, id: singletonID) else { throw SyncProjectionError.invalidKey(key) }
    }

    static func metadataRecords(
        profileID: UUID, directory: ProfileDirectory? = nil,
        includeAsset: (SyncRecordKey) throws -> Bool = { _ in true },
    ) throws -> [SyncRecordKey: SyncFields] {
        let directory = directory ?? .shared
        guard let profile = directory.profiles.first(where: { $0.id == profileID }) else { throw SyncProjectionError.unknownProfile(profileID) }
        let photo = try selectedPhoto(profile, directory: directory)
        let avatar = Avatar(kind: profile.avatar.kind, text: profile.avatar.text, assetID: photo?.key.recordID, photoExtension: photo?.ext)
        var records = try [SyncRecordKey(kind: metadataKind, id: singletonID): [
            "name": SyncJSON.encode(profile.name), "color": SyncJSON.encode(profile.color),
            "createdAt": SyncJSON.encode(profile.createdAt), "avatar": SyncJSON.encode(avatar),
        ]]
        if let photo, try includeAsset(photo.key) {
            records[photo.key] = try avatarAssetFields(photo.key, profileID: profileID, directory: directory)
        }
        return records
    }

    private static func materialize(_ photo: Photo, profileID: UUID, directory: ProfileDirectory) throws -> String {
        let archived = archive(profileID: profileID, directory: directory).appending(path: photo.key.recordID)
        guard FileManager.default.fileExists(atPath: archived.path) else {
            return filename(photo, profileID: profileID, pending: true)
        }
        let name = filename(photo, profileID: profileID, pending: false)
        let display = ProfilePhotoStore.url(named: name, in: directory.containerURL)
        if !FileManager.default.fileExists(atPath: display.path) {
            try FileManager.default.createDirectory(at: display.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.linkItem(at: archived, to: display)
        }
        return name
    }

    static func applyAvatarAsset(_ key: SyncRecordKey, fields: SyncFields?, profileID: UUID, directory: ProfileDirectory) throws {
        try validateAssetKey(key)
        guard var local = directory.profiles.first(where: { $0.id == profileID }) else { throw SyncProjectionError.unknownProfile(profileID) }
        guard let fields, fields.count == 1, let json = fields["bytes"],
              json.utf8.count <= 2 + (PiruProfilesSection.maxPhotoBytes + 2) / 3 * 4 else { throw SyncProjectionError.invalidField("bytes") }
        let encoded = try SyncJSON.decode(String.self, from: json)
        let bytes = try SyncWire.decodeBase64URL(encoded)
        guard (1 ... PiruProfilesSection.maxPhotoBytes).contains(bytes.count), Self.key(for: bytes) == key else {
            throw SyncProjectionError.invalidField("bytes")
        }
        try store(bytes, at: archive(profileID: profileID, directory: directory).appending(path: key.recordID))
        guard let name = local.avatar.photo else { return }
        let ext = (name as NSString).pathExtension
        let photo = Photo(key: key, ext: ext)
        guard extensions.contains(ext), name == filename(photo, profileID: profileID, pending: true) else { return }
        local.avatar.photo = try materialize(photo, profileID: profileID, directory: directory)
        try directory.update(local)
    }

    static func applyMetadata(
        _ key: SyncRecordKey, fields: SyncFields?, profileID: UUID, directory: ProfileDirectory? = nil,
    ) throws {
        try validateMetadataKey(key)
        let directory = directory ?? .shared
        guard let local = directory.profiles.first(where: { $0.id == profileID }) else { throw SyncProjectionError.unknownProfile(profileID) }
        guard let fields else { return }
        let name = try fields["name"].map { try SyncJSON.decode(String.self, from: $0) } ?? local.name
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SyncProjectionError.invalidField("name") }
        let color = try fields["color"].map { try SyncJSON.decode(ProfileColor.self, from: $0) } ?? local.color
        let createdAt = try fields["createdAt"].map { try SyncJSON.decode(Date.self, from: $0) } ?? local.createdAt
        var avatar = local.avatar
        if let json = fields["avatar"] {
            let incoming = try SyncJSON.decode(Avatar.self, from: json)
            var name: String?
            if let id = incoming.assetID {
                let key = SyncRecordKey(kind: avatarAssetKind, recordID: id)
                try validateAssetKey(key)
                guard let ext = incoming.photoExtension, extensions.contains(ext) else { throw SyncProjectionError.invalidField("avatar") }
                name = try materialize(Photo(key: key, ext: ext), profileID: profileID, directory: directory)
            } else if incoming.photoExtension != nil { throw SyncProjectionError.invalidField("avatar") }
            avatar = ProfileAvatar(kind: incoming.kind, text: incoming.text, photo: name)
        }
        let updated = PiruProfile(
            id: local.id,
            name: name,
            avatar: avatar,
            color: color,
            storeFileName: local.storeFileName,
            createdAt: createdAt,
        )
        if updated != local { try directory.update(updated) }
    }
}
