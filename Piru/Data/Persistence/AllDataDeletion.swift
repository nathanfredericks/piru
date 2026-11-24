import SwiftData
import UserNotifications
import WidgetKit

/// Delete Everything: the journal itself, then every store, cache, schedule
/// and system surface that holds a copy of it or would act on it.
///
/// The caller releases its journal references after the local erase succeeds,
/// before resetting notifications, backups and other system surfaces.
enum AllDataDeletion {
    /// Deletes every journal row in `context`'s store, with pending deferred
    /// bookkeeping cancelled first so none of it lands on the empty store.
    static func deleteJournal(context: ModelContext, account: SyncAccount = .shared) throws {
        let directory = account.linkDirectory ?? ProfileDirectory.shared
        let id = directory.activeProfileID
        guard let profile = directory.profiles.first(where: { $0.id == id }),
              try account.verifiedStore(for: profile, directory: directory) === context.container else { throw SyncAccount.Issue.changed }
        try account.detachForLocalErase(id)
        DoseLogService.shared.cancelPendingBookkeeping()
        try DataExportImport.deleteAll(context: context)
    }

    /// Resets the in-memory stores, the on-disk caches and recovery copies, the
    /// scheduled and delivered notifications, Live Activities, the automatic
    /// iCloud backup and the widgets. Returns the message of each cleanup step
    /// that failed; the steps after a failure still run.
    static func resetEverythingElse(context: ModelContext) async -> [String] {
        JournalResetGeneration.advance()
        DoseLogService.shared.changed()
        PhoneSyncCoordinator.shared.journalWasDeleted()
        ActiveSessionManager.shared.clearSession()
        DayResolveCache.shared.clear()
        NotificationPreferencesStore.shared.resetAfterDeletion()
        CustomSubstanceStore.shared.resetAfterDeletion()
        CustomUnitStore.shared.configure(container: context.container)
        SearchHistoryStore.shared.clear()
        QuickLogManager.suppressedRecents = []
        var cleanupErrors: [String] = []
        for cleanup in [
            { try UserProfileStore.shared.resetAfterDeletion() },
            { try StoreRecovery.deleteRecoveryCopies() },
            { try JournalDeriveCache.clear() },
            { try TimelineStripCache.clear() },
            { try BodyLevelsTrailCache.clear() },
        ] {
            do { try cleanup() } catch { cleanupErrors.append(error.localizedDescription) }
        }
        CheckInScheduler.cancelAll()
        let notifications = UNUserNotificationCenter.current()
        notifications.removeAllPendingNotificationRequests()
        notifications.removeAllDeliveredNotifications()
        await LiveActivityManager.shared.deleteJournalActivities()
        await BackupManager.shared.disableAndRemoveBackup()
        WidgetCenter.shared.reloadAllTimelines()
        return cleanupErrors
    }
}
