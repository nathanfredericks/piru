import Foundation
import Observation

/// Asks the user how a backup's profiles come back
/// (``ProfileRestoreConflict``) and hands the answer to the restore waiting on
/// it. One question at a time, as there is one restore at a time.
///
/// The sheet goes on the app's sheet stack (``SheetRoute/profileRestoreChoices``).
@Observable
@MainActor
final class ProfileRestoreRequest {
    static let shared = ProfileRestoreRequest()

    struct Pending: Identifiable {
        let id = UUID()
        let conflicts: [ProfileRestoreConflict]
    }

    private(set) var pending: Pending?
    @ObservationIgnored private var continuation: CheckedContinuation<[UUID: ProfileRestoreChoice]?, Never>?

    /// The user's choice for each conflict, or `nil` when they cancel.
    func ask(_ conflicts: [ProfileRestoreConflict], navigator: AppNavigator = .shared) async -> [UUID: ProfileRestoreChoice]? {
        finish(nil)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            pending = Pending(conflicts: conflicts)
            navigator.present(.profileRestoreChoices)
        }
    }

    /// Answer the restore that asked, once; later calls do nothing.
    func finish(_ choices: [UUID: ProfileRestoreChoice]?) {
        let waiting = continuation
        continuation = nil
        pending = nil
        waiting?.resume(returning: choices)
    }
}
