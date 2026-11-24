#if DEBUG
    import SwiftData
    import SwiftUI
    import UIKit

    /// Walks the app through every screen worth a screenshot and has the host
    /// capture each one — the in-process half of `pipeline/screenshots.py`.
    ///
    /// The tour is enabled by `-piruScreenshots <dir>` (an absolute path on the
    /// host, which a simulator app can write to). For each screen it navigates
    /// through `AppNavigator`, waits for the screen to settle, and then writes
    /// `<dir>/.tour/request.json` naming the file it wants. The host takes the
    /// screenshot with `simctl io screenshot` — so the status-bar override and
    /// every real pixel are in the picture — and answers with `<dir>/.tour/ack`.
    /// `<dir>/.tour/done.json` closes the run. The tour runs on its own store
    /// (`StoreRecovery.activeStoreName`).
    ///
    /// Arguments, all optional after the first:
    /// - `-piruScreenshots <dir>` — output directory; enables the tour.
    /// - `-piruScreenshotScreens all|<name,…>` — which screens (default all).
    /// - `-piruScreenshotSettle <seconds>` — wait after navigating (default 1.2).
    @MainActor
    enum ScreenshotTour {
        // MARK: - Launch arguments

        static var isRequested: Bool {
            argument(after: "-piruScreenshots") != nil
        }

        private static func argument(after flag: String) -> String? {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }

        private static func list(after flag: String) -> [String]? {
            guard let raw = argument(after: flag) else { return nil }
            return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        // MARK: - Screens

        /// One screen the tour can capture. Its file is numbered by its place
        /// in ``catalog``, so a name is stable when only a subset is captured.
        struct Screen {
            let name: String
            /// The persona whose seed this screen shows; `nil` for a screen every
            /// persona fills. A pass under another persona leaves it out.
            var persona: String?
            let stage: @MainActor (Stage) async -> Void
        }

        /// Every screen, in capture order. Names are the file names.
        static let catalog: [Screen] = [
            Screen(name: "journal") { stage in
                stage.tab(.journal)
            },
            Screen(name: "journal-days") { stage in
                stage.push(.journalDays, in: .journal)
            },
            Screen(name: "timeline") { stage in
                stage.grouping(.timeline)
                stage.push(.timeline, in: .journal)
            },
            Screen(name: "session") { stage in
                guard let id = stage.sessionID(titled: "Lake evening") else { return }
                stage.push(.session(id: id), in: .journal)
            },
            Screen(name: "entry") { stage in
                guard let entry = stage.newestEntry(of: "Methylphenidate") else { return }
                stage.tab(.journal)
                stage.present(.entryDetail(timestamp: entry.timestamp, id: entry.id))
            },
            Screen(name: "quicklog") { stage in
                stage.tab(.journal)
                stage.present(.quickLog(routine: MedTimeGroup.morning.slug))
            },
            Screen(name: "quicklog-substance") { stage in
                stage.tab(.journal)
                stage.present(.quickLog(routine: nil, prefillSubstance: "Caffeine"))
            },
            Screen(name: "library") { stage in
                stage.tab(.library)
            },
            Screen(name: "search") { stage in
                stage.tab(.search)
            },
            Screen(name: "search-results") { stage in
                stage.tab(.library)
                await stage.search("ket")
            },
            Screen(name: "substance-mdma") { stage in
                stage.push(.substance(name: "MDMA"), in: .library)
            },
            Screen(name: "substance-mdma-pharmacology") { stage in
                stage.push(.substanceData(name: "MDMA", section: .pharmacology), in: .library)
            },
            Screen(name: "substance-ketamine") { stage in
                stage.push(.substance(name: "Ketamine"), in: .library)
            },
            Screen(name: "substance-ketamine-chemistry") { stage in
                stage.push(.substanceData(name: "Ketamine", section: .chemistry), in: .library)
            },
            Screen(name: "substance-methylphenidate") { stage in
                stage.push(.substance(name: "Methylphenidate"), in: .library)
            },
            Screen(name: "tools") { stage in
                stage.tab(.tools)
            },
            Screen(name: "my-meds") { stage in
                stage.tab(.myMeds)
            },
            Screen(name: "inventory") { stage in
                stage.push(.tool(.inventory), in: .tools)
            },
            Screen(name: "interactions") { stage in
                Self.stagedInteraction = ["Alcohol", "Lorazepam"]
                stage.push(.tool(.interactions), in: .tools)
            },
            Screen(name: "half-life") { stage in
                stage.push(.tool(.calculator), in: .tools)
            },
            Screen(name: "insights") { stage in
                stage.tab(.insights)
            },
            Screen(name: "stats") { stage in
                stage.push(.insight(.usage), in: .insights)
            },
            Screen(name: "adherence") { stage in
                stage.push(.insight(.adherence), in: .insights)
            },
            Screen(name: "modeled-levels") { stage in
                stage.push(.insightGroup(.inYourBody), in: .insights)
            },
            Screen(name: "tolerance") { stage in
                stage.push(.insight(.tolerance), in: .insights)
            },
            Screen(name: "receptor-load") { stage in
                stage.push(.insight(.receptorLoad), in: .insights)
            },
            Screen(name: "settings") { stage in
                stage.tab(.journal)
                stage.present(.settings)
            },
            // New screens go last: a file's number is its place in this list,
            // so an insertion renumbers every capture after it.
            Screen(name: "quicklog-concerta") { stage in
                Self.stagedQuickLogSearch = "Concerta"
                stage.tab(.journal)
                stage.present(.quickLog(routine: nil))
            },
            // The sheet forms of My Meds, a med, and a stocked item: on iPad
            // each is a portrait panel, where the pushed screens fill a
            // landscape-wide canvas.
            Screen(name: "my-meds-sheet") { stage in
                stage.tab(.myMeds)
                stage.present(.dailyDoseSettings)
            },
            Screen(name: "med-concerta") { stage in
                guard let med = stage.med(product: "Concerta") else { return }
                stage.tab(.myMeds)
                stage.present(.dailyDoseSettings)
                await stage.settleSheet()
                stage.pushInSheet(.medDetail(identityKey: med.identityKey, sortOrder: med.sortOrder))
            },
            Screen(name: "inventory-concerta") { stage in
                guard let item = stage.inventoryItem(of: "Methylphenidate") else { return }
                stage.tab(.tools)
                stage.present(.inventoryItemEdit(id: item.id))
            },
            // Empty under the default `week` persona; capture it with
            // `pipeline/screenshots.py --persona transfemHRT` to see the curves.
            Screen(name: "hormone-levels") { stage in
                stage.push(.insight(.hormoneLevels), in: .insights)
            },
            Screen(name: "profiles") { stage in
                stage.tab(.journal)
                stage.present(.profiles)
            },
            // `sharedNight` seeds Alice and Bob and the night the three of them
            // shared: `pipeline/screenshots.py --persona sharedNight`.
            Screen(name: "shared-session", persona: "sharedNight") { stage in
                guard let id = stage.sessionID(titled: "Kitchen disco") else { return }
                stage.push(.session(id: id), in: .journal)
            },
            Screen(name: "shared-peek", persona: "sharedNight") { stage in
                guard let session = stage.session(titled: "Kitchen disco"),
                      let experience = session.sharedExperienceID,
                      let other = ProfileDirectory.shared.profiles.first(where: { !$0.isOwner })
                else { return }
                stage.push(.session(id: session.id), in: .journal)
                stage.present(.sharedSessionPeek(experienceID: experience, profileID: other.id))
            },
            Screen(name: "add-people", persona: "sharedNight") { stage in
                guard let id = stage.sessionID(titled: "Kitchen disco") else { return }
                stage.push(.session(id: id), in: .journal)
                stage.present(.addPeople(sessionID: id))
            },
            Screen(name: "journal-search-results") { stage in
                stage.tab(.journal)
                await stage.search("Caffeine")
            },
        ]

        // MARK: - Seams

        /// Substances the interaction checker adds on its next appearance;
        /// `.tool(.interactions)` carries no payload, so the tour hands them
        /// over here. Read once by `takeStagedInteraction()`.
        private static var stagedInteraction: [String] = []

        static func takeStagedInteraction() -> [String] {
            defer { stagedInteraction = [] }
            return stagedInteraction
        }

        /// A search the Quick Log sheet runs on its next appearance, staging the
        /// recent it finds with the editor open; `.quickLog` carries no search
        /// text. Read once by `takeStagedQuickLogSearch()`.
        private static var stagedQuickLogSearch: String?

        static func takeStagedQuickLogSearch() -> String? {
            defer { stagedQuickLogSearch = nil }
            return stagedQuickLogSearch
        }

        // MARK: - Run

        /// What the tour writes for one capture.
        private struct Request: Codable {
            let file: String
            let screen: String
            let index: Int
            let total: Int
        }

        private struct Report: Codable {
            var captured: [String] = []
            var skipped: [String] = []
            var failed: [String] = []
            var seconds: Double = 0
        }

        /// Runs the whole tour. Call once the store is seeded and the substance
        /// batch cache is warm; returns when `done.json` is on disk.
        static func run(container: ModelContainer) async {
            guard let root = argument(after: "-piruScreenshots") else { return }
            let started = Date.now
            print("ScreenshotTour: now is \(DebugClock.now.formatted(date: .abbreviated, time: .shortened))\(DebugClock.override == nil ? " (wall clock)" : " (pinned)")")
            let settle = argument(after: "-piruScreenshotSettle").flatMap(Double.init) ?? 1.2
            let screens = select(list(after: "-piruScreenshotScreens"), from: catalog)
            let tourDirectory = URL(filePath: root).appending(path: ".tour")
            try? FileManager.default.createDirectory(at: tourDirectory, withIntermediateDirectories: true)

            try? await Task.sleep(for: .seconds(1.5))
            await SubstanceStore.shared.ensureAllLoaded()

            let stage = Stage(context: container.mainContext)
            let originalGrouping = stage.currentGrouping
            var report = Report()
            var index = 0

            for screen in screens {
                index += 1
                let position = catalog.firstIndex { $0.name == screen.name }.map { $0 + 1 } ?? 0
                // Reserve slot 27 to keep the published filenames stable.
                let number = position >= 27 ? position + 1 : position
                let file = String(format: "%02d-%@.png", number, screen.name)
                if let needed = screen.persona, needed != argument(after: "-piruPersona") {
                    report.skipped.append(file)
                    print("ScreenshotTour: [\(index)/\(screens.count)] \(file) skipped — needs -piruPersona \(needed)")
                    continue
                }
                await stage.reset()
                await screen.stage(stage)
                try? await Task.sleep(for: .seconds(settle))
                let request = Request(file: file, screen: screen.name, index: index, total: screens.count)
                print("ScreenshotTour: [\(index)/\(screens.count)] \(file)")
                switch await handshake(request, in: tourDirectory) {
                case .captured: report.captured.append(file)
                case .timedOut: report.failed.append(file)
                }
            }

            await stage.reset()
            stage.restoreGrouping(originalGrouping)

            report.seconds = Date.now.timeIntervalSince(started)
            write(report, to: tourDirectory.appending(path: "done.json"))
            print("ScreenshotTour: done — \(report.captured.count) captured, \(report.failed.count) failed, \(report.skipped.count) skipped")
        }

        /// The screens a pass captures: the named ones, or every screen the
        /// running persona fills.
        private static func select(_ names: [String]?, from catalog: [Screen]) -> [Screen] {
            guard let names, names != ["all"] else {
                let persona = argument(after: "-piruPersona")
                return catalog.filter { $0.persona == nil || $0.persona == persona }
            }
            let unknown = names.filter { name in !catalog.contains { $0.name == name } }
            if !unknown.isEmpty {
                print("ScreenshotTour: unknown screens \(unknown) — known: \(catalog.map(\.name).joined(separator: ", "))")
            }
            return catalog.filter { names.contains($0.name) }
        }

        // MARK: - Handshake

        private enum Outcome { case captured, timedOut }

        /// Writes the request, waits for the host's ack (30 s), then clears both.
        private static func handshake(_ request: Request, in directory: URL) async -> Outcome {
            let requestURL = directory.appending(path: "request.json")
            let ackURL = directory.appending(path: "ack")
            write(request, to: requestURL)
            defer {
                try? FileManager.default.removeItem(at: ackURL)
                try? FileManager.default.removeItem(at: requestURL)
            }
            for _ in 0 ..< 600 {
                if FileManager.default.fileExists(atPath: ackURL.path) { return .captured }
                try? await Task.sleep(for: .milliseconds(50))
            }
            print("ScreenshotTour: no ack for \(request.file) — is pipeline/screenshots.py running?")
            return .timedOut
        }

        private static func write(_ value: some Encodable, to url: URL) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }

        // MARK: - Stage

        /// The moves a screen is staged with.
        @MainActor
        struct Stage {
            let context: ModelContext
            private let navigator = AppNavigator.shared
            private let groupDefaults = UserDefaults(suiteName: AppIdentity.appGroup)

            init(context: ModelContext) {
                self.context = context
            }

            /// Every sheet down, every stack popped to root.
            func reset() async {
                let hadSheet = !navigator.sheetStack.isEmpty
                navigator.dismissAll()
                navigator.resetAllPaths()
                try? await Task.sleep(for: .seconds(hadSheet ? 0.6 : 0.2))
            }

            func tab(_ tab: TabID) {
                navigator.select(tab)
            }

            func push(_ route: PushRoute, in tab: TabID) {
                let destination = TabRouting.destination(for: tab, path: [route])
                navigator.select(destination.tab)
                navigator.setPath(destination.path, in: destination.tab)
            }

            func present(_ sheet: SheetRoute) {
                navigator.present(sheet)
            }

            /// Waits out a sheet's presentation, so a push onto its stack
            /// lands on a settled sheet.
            func settleSheet() async {
                try? await Task.sleep(for: .seconds(0.8))
            }

            /// Pushes onto the top sheet's own stack.
            func pushInSheet(_ route: PushRoute) {
                navigator.push(route)
            }

            func med(product: String) -> DailyDoseItem? {
                var descriptor = FetchDescriptor<DailyDoseItem>(predicate: #Predicate { $0.productName == product })
                descriptor.fetchLimit = 1
                return try? context.fetch(descriptor).first
            }

            func inventoryItem(of substance: String) -> InventoryItem? {
                var descriptor = FetchDescriptor<InventoryItem>(predicate: #Predicate { $0.substance == substance })
                descriptor.fetchLimit = 1
                return try? context.fetch(descriptor).first
            }

            func grouping(_ grouping: JournalGrouping) {
                groupDefaults?.set(grouping.rawValue, forKey: "journalGrouping")
            }

            /// The grouping the device had before the tour, so the run can put
            /// it back: it lives in the App Group defaults the real app reads.
            var currentGrouping: String? {
                groupDefaults?.string(forKey: "journalGrouping")
            }

            func restoreGrouping(_ raw: String?) {
                groupDefaults?.set(raw, forKey: "journalGrouping")
            }

            func sessionID(titled title: String) -> UUID? {
                session(titled: title)?.id
            }

            func session(titled title: String) -> Session? {
                var descriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.title == title })
                descriptor.fetchLimit = 1
                return try? context.fetch(descriptor).first
            }

            func newestEntry(of substance: String) -> DoseEntry? {
                var descriptor = FetchDescriptor<DoseEntry>(
                    predicate: #Predicate { $0.substance == substance },
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)],
                )
                descriptor.fetchLimit = 1
                return try? context.fetch(descriptor).first
            }

            /// Focuses the active root's field and types `query` through UIKit:
            /// the field is a `UISearchTextField` under SwiftUI's `.searchable`,
            /// and its `editingChanged` action is what feeds the text binding.
            func search(_ query: String) async {
                try? await Task.sleep(for: .seconds(0.6))
                guard let field = Self.searchField() else {
                    print("ScreenshotTour: no search field on screen")
                    return
                }
                field.becomeFirstResponder()
                try? await Task.sleep(for: .seconds(0.4))
                field.text = query
                field.sendActions(for: .editingChanged)
            }

            private static func searchField() -> UISearchTextField? {
                for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                    for window in scene.windows where window.isKeyWindow {
                        if let field = searchField(in: window) { return field }
                    }
                }
                return nil
            }

            private static func searchField(in view: UIView) -> UISearchTextField? {
                guard !view.isHidden, view.alpha > 0 else { return nil }
                if let field = view as? UISearchTextField { return field }
                for subview in view.subviews {
                    if let field = searchField(in: subview) { return field }
                }
                return nil
            }
        }
    }
#endif
