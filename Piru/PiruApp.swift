import BackgroundTasks
import SwiftData
import SwiftUI
import UIKit
import UserNotifications
import WidgetKit

// A UIKit background-execution assertion that ends itself exactly once —
// explicitly via ``end()`` when the protected work finishes, or from the
// system's expiration handler if time runs out first.
@MainActor
private final class BackgroundTaskAssertion {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

// MARK: - App

@main
struct PiruApp: App {
    /// Whose journal is open, and its store. The root view reads the store from
    /// here, so a profile switch rebuilds the tree on the new one.
    private let profiles = ProfileDirectory.shared
    @Environment(\.scenePhase) private var scenePhase

    /// The active profile's store, for the launch and lifecycle calls.
    private var container: ModelContainer {
        profiles.activeContainer
    }

    init() {
        // Settings ▸ Language, before anything looks up a string.
        AppLanguageModel.applyAtLaunch()

        // Release every GRDB lock when the app is backgrounded, before the first
        // connection opens (the store probe in `openStore` is one): a lock held
        // into suspension is a 0xdead10cc kill. See DatabaseSuspension.
        DatabaseSuspension.install()

        // Opening the store reads, and on an update migrates, the App Group
        // SQLite file, and `init` also runs for prewarmed and background
        // launches, which iOS may suspend at any point. A suspension while
        // SQLite holds a lock there is a 0xdead10cc kill, so ask for the
        // process to stay up until the store is open. See BackgroundActivity.
        let storeOpening = BackgroundActivity.hold("Open journal store")

        // A successor install's first launch brings the legacy app's journal and
        // settings across before anything opens the store; the legacy build
        // publishes what only its sandbox can see for that successor to read.
        LegacyHandoff.importIfSuccessor()
        Self.publishLegacyHandoff()

        // Also binds every store-backed singleton (StoreBinding), among them
        // the Log Dose action's container — App Intents launch the app before
        // performing, so it is set before any `perform()` — and the Apple
        // Watch sync, which always writes into the owner's journal.
        AppLaunch.openStore()
        storeOpening.end()

        // Routes notification taps (routine reminders carry a piru:// deep
        // link). The center holds its delegate weakly — the shared instance
        // keeps it alive.
        UNUserNotificationCenter.current().delegate = DoseNotificationDelegate.shared

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: LiveActivityManager.backgroundTaskIdentifier,
            using: .main,
        ) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            LiveActivityManager.shared.handleBackgroundRefresh(task)
        }
    }

    #if DEBUG
        private static let forcesDifferentiateWithoutColor =
            ProcessInfo.processInfo.arguments.contains("-piruDifferentiateWithoutColor")
    #endif

    var body: some Scene {
        WindowGroup {
            ProfileRoot {
                if AppIdentity.isLegacy {
                    AppMovedView()
                } else {
                    root
                }
            }
            .task(id: SyncMonitorID(
                active: scenePhase == .active,
                profile: profiles.activeProfileID,
                linked: SyncAccount.shared.isLinked(localProfileID: profiles.activeProfileID),
            )) {
                guard scenePhase == .active, !AppIdentity.isLegacy else { return }
                await ProfileSync.shared.monitor(profileID: profiles.activeProfileID, container: container)
            }
            .task {
                guard !AppIdentity.isLegacy else { return }
                WidgetCenter.shared.reloadAllTimelines()
                await AppLaunch.finishLaunching(container: container)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !AppIdentity.isLegacy {
                AppLaunch.becameActive(container: container)
            }
            if phase == .background {
                enterBackground()
            }
        }
    }

    @ViewBuilder
    private var root: some View {
        #if DEBUG
            ContentView()
                .transformEnvironment(\._accessibilityDifferentiateWithoutColor) { value in
                    if Self.forcesDifferentiateWithoutColor { value = true }
                }
        #else
            ContentView()
        #endif
    }

    private func enterBackground() {
        // Tear down any live keyboard before suspension. Suspending with
        // a first responder up can strand UIKit's scene-level keyboard
        // state and affect the layout of sheets after foregrounding.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil,
        )
        Self.publishLegacyHandoff(backgrounding: true)
        // Hold a background-execution assertion across the await so
        // iOS can't suspend the process mid-write; ended on completion
        // or expiration, whichever comes first.
        let assertion = BackgroundTaskAssertion(name: "AutomaticBackup")
        Task {
            defer { assertion.end() }
            await AppLaunch.enteredBackground(container: container)
        }
    }

    /// Publish the legacy build's handoff off the main thread. On backgrounding
    /// it holds a background-execution assertion so the publish finishes before
    /// the process is suspended; at launch, from `init`, there is no
    /// `UIApplication` to ask yet. Returns at once in the successor.
    private static func publishLegacyHandoff(backgrounding: Bool = false) {
        guard AppIdentity.isLegacy else { return }
        let assertion = backgrounding ? BackgroundTaskAssertion(name: "LegacyHandoff") : nil
        Task.detached(name: "Publish legacy handoff", priority: .utility) {
            LegacyHandoff.publishIfLegacy()
            await assertion?.end()
        }
    }
}

private struct SyncMonitorID: Equatable {
    let active: Bool
    let profile: UUID
    let linked: Bool
}
