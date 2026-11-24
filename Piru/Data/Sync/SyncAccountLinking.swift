import Foundation
import SwiftData

extension SyncAccount {
    nonisolated enum LinkTarget: Codable, Equatable {
        case fresh
        case registered(store: String, created: Date)
    }

    /// The target is checked again immediately before committing the binding.
    /// Capturing its identity prevents a removed profile becoming an eligible new UUID.
    func isEmptyForLinking(_ id: UUID) throws -> Bool {
        guard try binding(id) == nil else { return false }
        return try linkTarget(id, requireActive: false) != nil
    }

    func linkTarget(_ id: UUID, requireActive: Bool) throws -> LinkTarget? {
        let directory = linkDirectory ?? ProfileDirectory.shared
        guard id != PiruProfile.legacyOwnerID, !directory.isPerson(id),
              !requireActive || directory.activeProfileID == id else { return nil }
        guard let profile = directory.profiles.first(where: { $0.id == id }) else {
            guard !requireActive else { return nil }
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.containerURL.path)
            let prefixes = [PiruProfile.storeFileName(for: id), PiruPerson.storeFileName(for: id)]
            guard !names.contains(where: { file in prefixes.contains(where: { file.hasPrefix($0) }) }) else { return nil }
            return .fresh
        }
        let container = try verifiedStore(for: profile, directory: directory)

        // Inspect unsaved authored changes on the UI context and committed rows
        // from a fresh context, including writes by widgets and other contexts.
        let models = StoreRecovery.userDataModels
        let authored = Set(models.map { ObjectIdentifier($0) })
        let main = container.mainContext
        if main.hasChanges {
            let pending = main.insertedModelsArray + main.changedModelsArray + main.deletedModelsArray
            if pending.contains(where: { authored.contains(ObjectIdentifier(type(of: $0))) }) { return nil }
        }
        let context = ModelContext(container)
        for model in models where try Self.containsRows(of: model, in: context) { return nil }
        return .registered(store: profile.storeFileName, created: profile.createdAt)
    }

    func verifiedStore(for profile: PiruProfile, directory: ProfileDirectory) throws -> ModelContainer {
        let url = directory.storeURL(for: profile).resolvingSymlinksInPath().standardizedFileURL
        guard let container = directory.container(for: profile.id, writable: true), container.configurations.count == 1,
              let config = container.configurations.first, !config.isStoredInMemoryOnly, config.allowsSave,
              config.url.resolvingSymlinksInPath().standardizedFileURL == url,
              StoreHealth.rowCount(at: url, tables: []) != nil else { throw Issue.storeUnavailable }
        return container
    }

    private static func containsRows<Row: PersistentModel>(of _: Row.Type, in context: ModelContext) throws -> Bool {
        try context.fetchCount(FetchDescriptor<Row>()) > 0
    }
}
