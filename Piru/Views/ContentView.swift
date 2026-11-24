import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appNavigator) private var navigator
    @Environment(\.modelContext) private var modelContext
    /// Substance titles resolve outside SwiftUI's dependency tracking (see
    /// `LocalizedSubstanceName`), so flipping the preference rebuilds the tab
    /// tree to redraw them. Navigation state lives in `AppNavigator` and the
    /// sheet stack is presented above this view, so nothing the user was on is lost.
    @AppStorage(LocalizedSubstanceName.englishNamesKey) private var englishSubstanceNames = false
    /// Settings ▸ Language rebuilds the tab tree the same way, so every string
    /// computed in a body is read again in the new language; the locale reaches
    /// the sheets above it through the environment.
    @State private var language = AppLanguageModel.shared
    #if DEBUG
        /// Whether `-piruRoute` / `-piruRouteTour` already ran this process.
        private static var handledLaunchRoute = false
    #endif

    /// The tab roots own search state. Launch presentations keep their own state
    /// outside the tab tree.
    var body: some View {
        rootNavigation
            .id(RootIdentity(englishSubstanceNames: englishSubstanceNames, localization: language.localization))
            .sheetStackPresenter(navigator)
            .dismissesKeyboardOnTap()
            .modifier(LaunchSheetModifier())
            .modifier(StoreDiagnosticsModifier())
            .onOpenURL { handleDeepLink($0) }
            .environment(\.locale, language.locale)
        #if DEBUG
            // `-piruRoute <piru://url>` lands on a screen at launch, for
            // simulator screenshots: `simctl openurl` is blocked by the
            // untappable "Open in Piru?" sheet. `-piruRouteTour` walks a list
            // of them in one session, for profiling (see `RouteTour`).
            .task {
                // Once per process: a profile switch rebuilds this view.
                guard !Self.handledLaunchRoute else { return }
                Self.handledLaunchRoute = true
                let args = ProcessInfo.processInfo.arguments
                if args.contains(ShareDemo.argument) {
                    await ShareDemo.run()
                    return
                }
                // A substance route resolves in the pushed view's body; a
                // cold `SubstanceStore.all` asserts in DEBUG.
                if let i = args.firstIndex(of: "-piruRoute"), args.indices.contains(i + 1),
                   let url = URL(string: args[i + 1]) {
                    await SubstanceStore.shared.ensureAllLoaded()
                    handleDeepLink(url)
                } else if let tour = RouteTour(arguments: args) {
                    await SubstanceStore.shared.ensureAllLoaded()
                    await tour.run(navigator: navigator) { url in
                        handleDeepLink(url.resolvingLatestSession(in: modelContext))
                    }
                }
            }
        #endif
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    ActiveSessionManager.shared.refresh()
                    // The foreground tick died with the suspension; the Lock
                    // Screen widget gets a current push and a re-armed tick.
                    LiveActivityManager.shared.resumeIfRunning()
                }
            }
    }

    /// The tab bar floats at the top on iPad and at the bottom on iPhone.
    private var rootNavigation: some View {
        MainTabView()
    }

    // MARK: - Deep Linking

    private func handleDeepLink(_ url: URL) {
        if ShareInbox.shared.handle(url) { return }
        if let link = DeepLink.decodeWebLink(url) {
            handleWebLink(link)
            return
        }
        // A link naming a profile switches to it first; the switch rebuilds
        // this view, so the route reads the navigator and store it lands on.
        ProfileSwitcher.open(url) { url in
            guard let outcome = DeepLink.decode(url) else { return }
            // A `piru://day` link targets the current session; resolving its
            // id here lets the navigator reveal an already-open session screen
            // instead of presenting a duplicate sheet over it.
            let context = ProfileDirectory.shared.activeContainer.mainContext
            let sessionID = outcome.sheet == .sessionDetail ? mostRecentSessionID(in: context) : nil
            AppNavigator.shared.apply(outcome, currentSessionID: sessionID)
        }
    }

    /// A dose.wiki link names its substance by article slug, which resolves
    /// only against the loaded catalog. On a cold start the link arrives while
    /// the launch prewarm is still running, so it waits for it here and then
    /// lands exactly where the matching `piru://` link would.
    private func handleWebLink(_ link: DosewikiLink) {
        Task(name: "Open dose.wiki link") {
            await SubstanceStore.shared.ensureAllLoaded()
            let name = link.slug.flatMap(SubstanceLibrary.name(forDosewikiSlug:))
            guard let outcome = link.outcome(substanceName: name) else { return }
            navigator.apply(outcome)
        }
    }
}

/// The session the `.sessionDetail` sheet would resolve — the most recent by
/// start date (mirrors `CurrentSessionHost`). The deep-link handler and session
/// accessory use it to reveal an open session without presenting a duplicate.
func mostRecentSessionID(in context: ModelContext) -> UUID? {
    var descriptor = FetchDescriptor<Session>(sortBy: [SortDescriptor(\.startDate, order: .reverse)])
    descriptor.fetchLimit = 1
    return try? context.fetch(descriptor).first?.id
}

// MARK: - Launch Chrome Modifiers

/// Launch-time store-health reassurance: when the persistent store can't be
/// opened the app runs in-memory and this surfaces a "your data is safe" alert
/// plus an off-main diagnostics export. Owns all of that churning `@State`.
private struct StoreDiagnosticsModifier: ViewModifier {
    @State private var storeLaunch = StoreLaunchState.shared
    @State private var dismissedStoreAlert = false
    @State private var preparingDiagnostics = false
    @State private var diagnosticsFile: DiagnosticsFile?
    @State private var diagnosticsError: String?

    func body(content: Content) -> some View {
        content
            .alert("Your Data Is Safe", isPresented: storeUnavailableAlertBinding) {
                Button("Send Logs to Developer") { prepareDiagnostics() }
                Button("OK", role: .cancel) {}
            } message: {
                Text("Piru couldn't open your journal this time, so it's running with temporary storage. **Nothing has been deleted.** Your doses and sessions are safe on this device and a future update will restore them automatically.\n\nSending the logs helps us ship that fix faster. They describe the storage problem only, never your dose data.")
            }
            .sheet(item: $diagnosticsFile, onDismiss: cleanupDiagnostics) { file in
                ShareSheet(items: [file.url])
            }
            .alert("Couldn't Prepare Logs", isPresented: diagnosticsErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(diagnosticsError ?? "")
            }
            .overlay {
                if preparingDiagnostics {
                    ProgressView().controlSize(.large)
                        .padding(Spacing.xxxl)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.CornerRadius.container))
                }
            }
    }

    private var diagnosticsErrorBinding: Binding<Bool> {
        Binding(get: { diagnosticsError != nil }, set: { if !$0 { diagnosticsError = nil } })
    }

    /// Shows the reassurance alert when the store is unavailable, until dismissed.
    private var storeUnavailableAlertBinding: Binding<Bool> {
        Binding(
            get: { storeLaunch.storeUnavailable && !dismissedStoreAlert },
            set: { if !$0 { dismissedStoreAlert = true } },
        )
    }

    /// Build the diagnostics report off the main actor, then present a share sheet.
    /// On failure, surface an error — never leave the user tapping with no result.
    private func prepareDiagnostics() {
        preparingDiagnostics = true
        Task {
            defer { preparingDiagnostics = false }
            do {
                let url = try await StoreDiagnostics.writeReport()
                diagnosticsFile = DiagnosticsFile(url: url)
            } catch {
                diagnosticsError = error.localizedDescription
            }
        }
    }

    private func cleanupDiagnostics() {
        if let url = diagnosticsFile?.url { try? FileManager.default.removeItem(at: url) }
        diagnosticsFile = nil
    }
}

// MARK: - Main Tab View

private struct MainTabView: View {
    @Environment(\.appNavigator) private var navigator

    var body: some View {
        TabView(selection: Binding(get: { navigator.selectedTab }, set: { navigator.select($0) })) {
            ForEach(TabID.visible, id: \.self) { tab in
                Tab(value: tab) {
                    SplitNavigationView(tab: tab) {
                        switch tab {
                        case .stock(.journal): JournalTabRoot()
                        case .stock(.myMeds): MyMedsHubView().appNavigationBar("My Meds")
                        case .stock(.library): LibraryTabRoot()
                        case .stock(.insights): InsightsView()
                        default: EmptyView()
                        }
                    }
                } label: {
                    Label {
                        Text(tab.title)
                    } icon: {
                        Image(systemName: tab.systemImage)
                    }
                }
            }
        }
    }
}

private struct JournalTabRoot: View {
    @State private var searchText = ""

    var body: some View {
        TodayJournalView(searchText: $searchText)
            .appNavigationBar("Journal")
            .searchable(text: $searchText, prompt: Text("Search entries..."))
    }
}
/// Identifiable wrapper so a generated diagnostics file can drive a `.sheet(item:)`.
private struct DiagnosticsFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// What the tab tree is rebuilt on: the inputs a substance title or a looked-up
/// string reads outside SwiftUI's dependency tracking.
private struct RootIdentity: Hashable {
    let englishSubstanceNames: Bool
    let localization: String
}
