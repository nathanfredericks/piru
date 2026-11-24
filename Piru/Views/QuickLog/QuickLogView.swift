import SwiftData
import SwiftUI
import VisionKit

/// Gives the sheet a fixed, bounded history window for recents and warnings.
struct QuickLogSheet: View {
    var prestagedRoutine: String?
    /// Canonical name of a substance to stage (with its editor open) on present.
    var prefillSubstance: String?
    /// A complete dose for `prefillSubstance` — the box scanner's hand-off.
    var prefillDose: DosePrefill?
    /// The route to stage `prefillSubstance` on, in place of its default.
    var prefillRoute: RouteOfAdministration?
    var prefillDate: Date?

    private static let recentWindowDays: TimeInterval = 120

    @State private var cutoff = Date.now.addingTimeInterval(-recentWindowDays * 86_400)

    var body: some View {
        QuickLogView(
            prestagedRoutine: prestagedRoutine,
            prefillSubstance: prefillSubstance,
            prefillDose: prefillDose,
            prefillRoute: prefillRoute,
            prefillDate: prefillDate,
            historyCutoff: cutoff,
        )
    }
}

struct QuickLogView: View {
    let prestagedRoutine: String?
    let prefillSubstance: String?
    let prefillDose: DosePrefill?
    let prefillRoute: RouteOfAdministration?
    let prefillDate: Date?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.appNavigator) private var navigator
    @Environment(\.profileDirectory) private var directory

    @Query private var allEntries: [DoseEntry]
    @Query private var substanceColors: [SubstanceColor]
    @Query(sort: \DailyDoseItem.sortOrder) private var dailyDoseItems: [DailyDoseItem]
    @Query(sort: [SortDescriptor(\FavoriteSubstance.sortOrder), SortDescriptor(\FavoriteSubstance.createdAt, order: .reverse)])
    private var favorites: [FavoriteSubstance]
    @Query private var quickLogDoses: [QuickLogDose]

    @AppStorage(QuickLogManager.fixedOrderDefaultsKey) private var fixedOrder = false
    @State private var content = QuickLogContentModel()
    @State private var tray = DoseTrayModel()
    @State private var customStore = CustomSubstanceStore.shared
    @State private var path: [Page] = []
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var searchedText = ""
    @State private var showingDiscard = false
    @State private var showingCustomForm = false
    @State private var pendingCustom: CustomSubstanceEntry?
    @State private var commitError: CommitError?
    @State private var isCommitted = false
    @State private var pendingScan: QuickLogStagePayload?
    @State private var pendingScanQuery: String?

    private enum Page: Hashable {
        case dose(UUID)
        case recentAmounts(String)
        case browse
        case combination(String)
        case scanner
        case location
        case options
    }

    private enum CommitError {
        case save
        case profile
    }

    init(
        prestagedRoutine: String? = nil,
        prefillSubstance: String? = nil,
        prefillDose: DosePrefill? = nil,
        prefillRoute: RouteOfAdministration? = nil,
        prefillDate: Date?,
        historyCutoff: Date,
    ) {
        self.prestagedRoutine = prestagedRoutine
        self.prefillSubstance = prefillSubstance
        self.prefillDose = prefillDose
        self.prefillRoute = prefillRoute
        self.prefillDate = prefillDate
        _allEntries = Query(
            FetchDescriptor(
                predicate: #Predicate<DoseEntry> { $0.timestamp >= historyCutoff },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)],
            ),
            transaction: Transaction(animation: nil),
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !searchText.isEmpty {
                    searchResults
                } else if searchPresented {
                    suggestions
                } else {
                    stagedSection
                    if tray.isEmpty {
                        suggestions
                    } else {
                        QuickLogDetails(tray: tray, content: content) { path.append(.location) }
                        TrayWarningBanner(model: tray, content: content)
                        if let commitError {
                            Section {
                                Label(
                                    commitError == .profile ? "Choose a profile to record these entries." : "Couldn’t save entries. Try again.",
                                    systemImage: "exclamationmark.circle",
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, isPresented: $searchPresented, prompt: "Search substances")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: close)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(recordLabel, action: commitTray)
                        .disabled(!tray.isCommittable || isCommitted || searchPresented)
                }
            }
            .navigationDestination(for: Page.self, destination: destination)
        }
        .onChange(of: path) { oldPath, newPath in
            guard oldPath.last == .scanner, newPath.last != .scanner else { return }
            if let pendingScan {
                self.pendingScan = nil
                stage(pendingScan)
            } else if let pendingScanQuery {
                self.pendingScanQuery = nil
                searchText = pendingScanQuery
                searchPresented = true
            }
        }
        .interactiveDismissDisabled(!tray.isEmpty)
        .confirmationDialog("Discard Entries?", isPresented: $showingDiscard, titleVisibility: .visible) {
            Button("Discard Entries", role: .destructive) { navigator.dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .sheet(isPresented: $showingCustomForm, onDismiss: stageSavedCustom) {
            CustomSubstanceFormView(initialName: searchText.trimmingCharacters(in: .whitespaces)) {
                pendingCustom = $0
            }
        }
        .task { await load() }
        .task(id: searchText) { await search() }
        .onChange(of: favorites.map(\.persistentModelID)) { content.rebuildFavorites(favorites: favorites) }
        .onChange(of: quickLogDoses.count) { content.rebuildCards(quickLogDoses: quickLogDoses, favorites: favorites) }
        .task(id: DoseLogService.shared.revision) {
            guard content.hasLoaded, !isCommitted else { return }
            content.rebuildEntryDerived(allEntries: allEntries, dailyDoseItems: dailyDoseItems)
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        if !content.hasLoaded {
            ProgressView()
        } else {
            if !content.cachedFavoriteCards.isEmpty || !content.cachedFavoriteLibrarySubstances.isEmpty {
                Section("Favorites") {
                    ForEach(content.cachedFavoriteCards) { recentRow($0, isFavorite: true) }
                    resultRows(content.cachedFavoriteLibrarySubstances.map { .custom($0) })
                }
            }
            if !content.cachedNonFavoriteCards.isEmpty {
                Section("Recents") {
                    ForEach(content.cachedNonFavoriteCards) { recentRow($0, isFavorite: false) }
                }
            }
            if !dailyDoseItems.isEmpty {
                Section("My Meds") {
                    ForEach(dailyDoseItems.filter { !$0.isBackgroundMed }) { item in
                        Button {
                            stageDailyItem(item)
                            if let name = item.productName, customStore.combination(named: name) != nil {
                                path.append(.combination(name))
                            } else if let dose = tray.staged.last(where: { $0.route == item.route && $0.isFromDailySet && $0.combinationName == nil &&
                                    ($0.substanceName == item.substance || $0.productName == item.productName && item.productName != nil)
                            }) {
                                path.append(.dose(dose.id))
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(verbatim: item.productName ?? customStore.displayName(for: item.substance))
                                Text(verbatim: "\(item.amount.doseFormatted) \(item.unit)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                NavigationLink(value: Page.browse) { Label("Browse", systemImage: "list.bullet") }
                if DataScannerViewController.isSupported {
                    NavigationLink(value: Page.scanner) { Label("Scan a label", systemImage: "camera") }
                }
                NavigationLink(value: Page.options) { Label("Edit", systemImage: "slider.horizontal.3") }
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if CrisisKeywords.matches(searchText) {
            QuickLogHelpBanner()
        } else {
            if !content.hasLoaded || searchedText != searchText {
                ProgressView()
            } else {
                let matches = results
                if matches.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    resultRows(matches)
                }
                Button("Create Custom Substance", systemImage: "plus") { showingCustomForm = true }
            }
        }
    }

    private func resultRows(_ results: [QuickLogSearchResult]) -> some View {
        QuickLogSearchResults(results: results, onAdd: stage, onAddCombination: stageCombination)
    }

    private func recentRow(_ card: SubstanceCard, isFavorite: Bool) -> some View {
        resultRows([.recent(card)])
            .contextMenu {
                Button("Recent Amounts", systemImage: "list.bullet") { path.append(.recentAmounts(card.id)) }
                Button(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "star.slash" : "star") {
                    toggleFavorite(card)
                }
                Button("Remove from Recents", systemImage: "trash", role: .destructive) {
                    QuickLogManager.removeFromRecents(identityKey: card.id, context: modelContext)
                    content.rebuildCards(quickLogDoses: quickLogDoses, favorites: favorites)
                }
            }
    }

    private func toggleFavorite(_ card: SubstanceCard) {
        let isFavorite = FavoriteService.toggle(
            substance: card.substanceName, substanceUID: card.substanceUID,
            isomer: card.isomer, releaseForm: card.releaseForm, saltForm: card.saltForm,
            productName: card.productName, in: modelContext,
        )
        content.setFavorite(identity: card.id, on: isFavorite)
        content.rebuildFavorites(favorites: favorites)
    }

    @ViewBuilder
    private var stagedSection: some View {
        if !tray.isEmpty {
            Section("Entries") {
                ForEach(tray.staged) { item in
                    if item.combinationName == nil {
                        NavigationLink(value: Page.dose(item.id)) {
                            doseSummary(item)
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button("Remove", role: .destructive) { tray.remove(item) }
                        }
                    } else if let name = item.combinationName, tray.leadRowID(ofCombination: name) == item.id {
                        NavigationLink(value: Page.combination(name)) {
                            VStack(alignment: .leading) {
                                Text(verbatim: name)
                                ForEach(tray.staged.filter { $0.combinationName == name }) { dose in
                                    doseSummary(dose)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button("Remove", role: .destructive) { tray.removeCombination(name) }
                        }
                    }
                }
                Button("Add Another", systemImage: "plus") { searchPresented = true }
            }
        }
    }

    private func doseSummary(_ item: StagedDose) -> some View {
        VStack(alignment: .leading) {
            Text(verbatim: item.displayTitle)
            HStack {
                if item.isUnknownAmount {
                    Text("Unknown")
                } else if item.totalAmount <= 0 {
                    Text("Needs an amount")
                } else {
                    Text(verbatim: "\(item.totalAmount.doseFormatted) \(item.unit.unitDisplay(for: item.totalAmount))")
                }
                Text(item.route.localizedName)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func destination(_ page: Page) -> some View {
        switch page {
        case let .dose(id):
            if let dose = tray.staged.first(where: { $0.id == id }) {
                StagedDoseEditor(
                    item: doseBinding(dose), time: tray.time,
                    lastDose: tray.recipientID == nil ? content.cachedMostRecent[dose.identityKey] : nil,
                ) {
                    guard path.last == page else { return }
                    path.removeLast()
                    tray.remove(dose)
                }
            }
        case let .combination(name):
            if let product = customStore.combination(named: name) {
                StagedProductEditor(product: product, model: tray) {
                    guard path.last == page else { return }
                    path.removeLast()
                    tray.removeCombination(name)
                }
            }
        case let .recentAmounts(id):
            if let card = content.cachedCards.first(where: { $0.id == id }) {
                List {
                    ForEach(card.routes) { group in
                        Section {
                            ForEach(group.doses) { chip in
                                Button {
                                    guard path.last == page else { return }
                                    path.removeLast()
                                    stage(QuickLogSearchResult.recentPayload(card: card, group: group, chip: chip))
                                } label: {
                                    VStack(alignment: .leading) {
                                        if let name = chip.drinkName { Text(verbatim: name) }
                                        Text(verbatim: chip.detailLine)
                                    }
                                }
                            }
                        } header: {
                            Text(group.route.localizedName)
                        }
                    }
                }
                .navigationTitle(card.title ?? card.substanceName)
            }
        case .browse:
            QuickLogBrowsePage { payload in
                path = []
                stage(payload)
            }
        case .scanner:
            LabelScannerView(onResolved: { resolved in
                pendingScan = QuickLogStagePayload(
                    substance: resolved.canonicalName, route: resolved.stagingRoute, unit: resolved.stagingUnit,
                    amount: resolved.stagingAmount, tint: nil, librarySubstance: resolved.substance,
                    productName: resolved.brandName,
                )
            }, onSearch: { pendingScanQuery = $0 })
                .toolbar(.hidden, for: .navigationBar)
        case .location:
            QuickLogLocationPage(recents: content.cachedRecentLocations) {
                guard path.last == page else { return }
                tray.location = $0
                path.removeLast()
            }
        case .options:
            QuickLogEditSheet()
        }
    }

    private func doseBinding(_ dose: StagedDose) -> Binding<StagedDose> {
        Binding(
            get: { tray.staged.first(where: { $0.id == dose.id }) ?? dose },
            set: { updated in
                guard let index = tray.staged.firstIndex(where: { $0.id == dose.id }) else { return }
                tray.staged[index] = updated
            },
        )
    }

    private func load() async {
        guard !content.hasLoaded else { return }
        await SubstanceStore.shared.ensureAllLoaded()
        guard !Task.isCancelled else { return }
        QuickLogManager.seedIfNeeded(history: allEntries, context: modelContext)
        content.rebuildColorLookup(substanceColors: substanceColors)
        content.rebuildCards(quickLogDoses: quickLogDoses, favorites: favorites)
        content.rebuildEntryDerived(allEntries: allEntries, dailyDoseItems: dailyDoseItems)
        if let prestagedRoutine { stageRoutine(named: prestagedRoutine) }
        if prefillDate != nil || prefillSubstance != nil || prefillDose != nil {
            await stagePrefill(named: prefillSubstance)
            if prefillSubstance != nil { openLastDose() }
        }
        #if DEBUG
            if let query = ScreenshotTour.takeStagedQuickLogSearch(),
               let card = content.cachedCards.first(where: {
                   $0.substanceName.localizedCaseInsensitiveContains(query)
                       || $0.productName?.localizedCaseInsensitiveContains(query) == true
                       || $0.title?.localizedCaseInsensitiveContains(query) == true
               }), let payload = QuickLogSearchResult.recent(card).payload {
                stage(payload)
            }
        #endif
        content.markLoaded()
    }

    private func search() async {
        let query = searchText
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            content.setLibraryResults([])
            searchedText = query
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let matches = await SubstanceLibrary.searchMatchesAsync(query)
        guard !Task.isCancelled else { return }
        content.setLibraryResults(matches)
        searchedText = query
    }

    private var results: [QuickLogSearchResult] {
        let query = searchText.lowercased()
        guard !query.isEmpty else { return [] }
        let recentCards = content.cachedCards
            // Match the card's names, not its id — the id is an opaque
            // substance-identity key (a PSID uid), so filtering on it would miss
            // a resolved card by its own name. Matching the product/form title
            // too makes a Concerta recents chip findable by "concerta".
            .filter { card in
                card.substanceName.lowercased().contains(query)
                    || card.title?.lowercased().contains(query) == true
                    || card.productName?.lowercased().contains(query) == true
            }
            .prefix(2)

        // The same catalog substance can be both a recent and a library hit —
        // list it once. A library match is a duplicate when it shares a recent's
        // PSID uid or, failing that, its canonical name; a genuinely custom
        // substance (no uid, distinct name) collides with neither.
        let recentUIDs = Set(recentCards.compactMap(\.substanceUID).filter { !$0.isEmpty })
        let recentNames = Set(recentCards.map { $0.substanceName.lowercased() })

        var results: [QuickLogSearchResult] = recentCards.map { .recent($0) }
        results += matchingCustomEntries.filter(\.isCombination).map { .combination($0) }
        results += content.cachedLibraryResults
            .filter { match in
                // An ester match ("Estradiol Valerate") is a distinct form from a
                // plain-Estradiol recent — it stages a different dose (the ester
                // pre-set), so keep it rather than dedup it against the base.
                if let alias = match.matchedAlias, SubstanceLibrary.saltForm(for: alias) != nil { return true }
                let uidDuplicate = match.substance.substanceUID.map { !$0.isEmpty && recentUIDs.contains($0) } ?? false
                return !(uidDuplicate || recentNames.contains(match.substance.name.lowercased()))
            }
            .prefix(30)
            .map { .library($0) }
        results += matchingCustomEntries.filter { !$0.isCombination }
            .map { .custom(SubstanceLibrary.lookup($0.name) ?? $0.asSubstance) }
        return results
    }

    /// The custom entries whose canonical name OR personal display name holds
    /// the query, so a relabeled substance is findable by the name the user
    /// gave it. Entries already covered by a recent card or a library hit are
    /// left out.
    private var matchingCustomEntries: [CustomSubstanceEntry] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        let libraryNames = Set(content.cachedLibraryResults.map { $0.substance.name.lowercased() })
        return customStore.all.filter { custom in
            let nameLower = custom.name.lowercased()
            let displayLower = custom.displayName?.lowercased() ?? ""
            let matches = nameLower.contains(query) || (!displayLower.isEmpty && displayLower.contains(query))
            return matches
                && !content.cachedHistoryNames.contains(nameLower)
                && !libraryNames.contains(nameLower)
        }
    }

    private func stage(_ payload: QuickLogStagePayload) {
        let tint = payload.tint ?? SubstancePalette.tint(for: payload.substance, tintMap: content.cachedColorLookup)
        let volumeCapability = payload.librarySubstance?.byVolumeDosing
        let needsVolume = volumeCapability?.offersVolumeInput(on: payload.route) == true && payload.volumeML == nil
        if payload.amount <= 0 || needsVolume {
            tray.stageDraft(
                substance: payload.substance, route: payload.route, unit: payload.unit, tint: tint,
                librarySubstance: payload.librarySubstance, productName: payload.productName, saltForm: payload.saltForm,
            )
        } else {
            tray.stage(
                substance: payload.substance, route: payload.route, amount: payload.amount, unit: payload.unit,
                tint: tint, librarySubstance: payload.librarySubstance, productName: payload.productName,
                saltForm: payload.saltForm, volumeML: payload.volumeML, abv: payload.abv,
                drinkName: payload.drinkName, emoji: payload.emoji,
            )
        }
        let identity = DoseTrayModel.stagedIdentity(
            substance: payload.substance, productName: payload.productName,
            librarySubstance: payload.librarySubstance, route: payload.route, saltForm: payload.saltForm,
        )
        endSearch()
        let unit = payload.amount <= 0 || needsVolume ? (volumeCapability?.canonicalUnit ?? payload.unit) : payload.unit
        if let row = tray.staged.last(where: {
            $0.identityKey == identity && $0.route == payload.route && $0.unit == unit && $0.combinationName == nil
        }) {
            path.append(.dose(row.id))
        }
    }

    private func stageCombination(_ product: CustomSubstanceEntry) {
        tray.stage(product: product, amount: 1, colorLookup: content.cachedColorLookup)
        if product.isLiquidCombination { tray.openVolume(ofCombination: product.name) }
        endSearch()
        path.append(.combination(product.name))
    }

    private func stageSavedCustom() {
        guard let saved = pendingCustom else { return }
        pendingCustom = nil
        if saved.isCombination {
            stageCombination(saved)
        } else {
            stage(QuickLogStagePayload(
                substance: saved.name, route: saved.defaultRoute, unit: saved.unit,
                amount: 0, tint: nil, librarySubstance: SubstanceLibrary.lookup(saved.name) ?? saved.asSubstance,
            ))
        }
    }

    private func openLastDose() {
        guard let item = tray.staged.last else { return }
        endSearch()
        if let combination = item.combinationName {
            path.append(.combination(combination))
        } else {
            path.append(.dose(item.id))
        }
    }

    private func endSearch() {
        searchPresented = false
        searchText = ""
    }

    private func stageDailyItem(_ item: DailyDoseItem) {
        tray.stage(dailyItem: item, colorLookup: content.cachedColorLookup)
    }

    private func stagedQuantity(_ item: DailyDoseItem) -> Int {
        tray.quantity(substance: item.substance, productName: item.productName, route: item.route, amount: item.amount, unit: item.unit)
    }

    /// Stage the items for a routine-reminder notification without duplicating them.
    private func stageRoutine(named name: String) {
        // Current reminders carry a time-group slug. Older links identify the
        // routine by its saved category.
        let items: [DailyDoseItem] = if let group = MedTimeGroup(slug: name) {
            dailyDoseItems.filter { MedTimeGroup.belongs($0, to: group) }
        } else {
            dailyDoseItems.filter { $0.category == name }
        }
        guard !items.isEmpty else { return }
        withAnimation(.snappy) {
            for item in items where stagedQuantity(item) == 0 {
                stageDailyItem(item)
            }
        }
    }

    /// Stage what the opener already knows. The tray-wide fields come first —
    /// time, stomach and tags belong to the tray, so they apply even when
    /// `name` resolves to nothing. Then `name` stages as a complete dose when
    /// an amount is known (a scanned box, a link, the Start Dose Log action),
    /// else as a draft — the path a search hit takes ("Add & edit"): the
    /// reference dose for the route is seeded and the editor opens, so the
    /// sheet lands on the dose the user came to enter rather than on the card
    /// list. A brand typed as the name stays on the row as its product, the way
    /// the search row keeps it. No row for an unknown name.
    private func stagePrefill(named name: String?) async {
        if let time = prefillDate ?? prefillDose?.time {
            tray.time = .custom(time)
        }
        if let meal = prefillDose?.meal {
            tray.meal = meal
        }
        if let tags = prefillDose?.tags {
            tray.tags.formUnion(tags)
        }
        guard let name else { return }
        if let combination = CustomSubstanceStore.shared.combination(named: name) {
            // A combination stages one row per component; the amount counts
            // units of the product (two co-codamol), never milligrams — or,
            // for a liquid, milliliters of it. A liquid opened with no amount
            // lands on its volume field.
            withAnimation(.snappy) {
                if combination.isLiquidCombination {
                    let volume = CombinationComponent.volumeML(for: prefillDose?.amount)
                    tray.stage(combination: combination, volumeML: volume, colorLookup: content.cachedColorLookup)
                    if prefillDose?.amount == nil { tray.openVolume(ofCombination: combination.name) }
                } else {
                    let quantity = CombinationComponent.units(for: prefillDose?.amount)
                    tray.stage(combination: combination, quantity: quantity, colorLookup: content.cachedColorLookup)
                }
                if let note = prefillDose?.note {
                    for index in tray.staged.indices where tray.staged[index].combinationName == combination.name {
                        tray.staged[index].note = note
                    }
                }
            }
            return
        }
        guard let named = await SubstanceLibrary.resolveNamed(name) else { return }
        let substance = named.substance
        let route = prefillRoute ?? named.esterRoute ?? substance.defaultRoute
        let unit = prefillDose?.unit ?? substance.unit(for: route, saltForm: named.saltForm)
        let productName = prefillDose?.productName ?? named.productName
        let tint = SubstancePalette.tint(for: substance.name, tintMap: content.cachedColorLookup)
        withAnimation(.snappy) {
            if let amount = prefillDose?.amount {
                tray.stage(
                    substance: substance.name,
                    route: route,
                    amount: amount,
                    unit: unit,
                    tint: tint,
                    librarySubstance: substance,
                    productName: productName,
                    saltForm: named.saltForm,
                )
            } else {
                tray.stageDraft(
                    substance: substance.name,
                    route: route,
                    unit: unit,
                    tint: tint,
                    librarySubstance: substance,
                    productName: productName,
                    saltForm: named.saltForm,
                )
            }
            if let note = prefillDose?.note,
               let index = tray.staged.lastIndex(where: { $0.substanceName == substance.name && $0.route == route }) {
                tray.staged[index].note = note
            }
        }
    }

    private var recordLabel: String {
        let count = tray.staged.count
        if let id = tray.recipientID, let recipient = directory.profile(id: id) {
            return count == 1
                ? String(localized: "Record for \(recipient.name)")
                : String(localized: "Record \(count) Entries for \(recipient.name)")
        }
        return count <= 1 ? String(localized: "Record an entry") : String(localized: "Record \(count) Entries")
    }

    private func close() {
        if tray.isEmpty {
            navigator.dismiss()
        } else {
            showingDiscard = true
        }
    }

    private func commitTray() {
        guard tray.isCommittable, !isCommitted else { return }
        let recipient: DoseRecipient
        if let id = tray.recipientID, id != directory.activeProfileID {
            guard let other = DoseRecipient.other(id, directory: directory) else {
                commitError = .profile
                return
            }
            recipient = other
        } else {
            recipient = .active(context: modelContext, colors: substanceColors, recentEntries: allEntries)
        }

        let time = tray.time.resolved
        let calendar = Calendar.current
        let isToday = calendar.isJournalDayToday(calendar.journalDay(for: time)) && time <= Date.now
        let tags = tray.tags.sorted()
        var batch: [(entry: DoseEntry, substance: Substance?)] = []
        var curation: [QuickLogManager.LoggedDose] = []
        for item in tray.staged {
            let entry = item.makeEntry(timestamp: time, tags: tags, meal: tray.meal, location: tray.location)
            batch.append((entry, item.librarySubstance))
            if !item.isFromDailySet, !item.isUnknownAmount, item.combinationName == nil {
                for component in item.components {
                    curation.append(QuickLogManager.LoggedDose(
                        substance: item.substanceName, route: item.route, amount: component.amount, unit: item.unit,
                        volumeML: item.volumeML,
                        abv: item.abv,
                        drinkName: item.drinkName, emoji: item.emoji,
                        substanceUID: item.substanceUID, isomer: item.isomer,
                        releaseForm: item.releaseForm, saltForm: item.saltForm, productName: item.productName,
                    ))
                }
            }
        }

        let entries = batch.map(\.entry)
        let liveSession = !recipient.isActive && isToday ? ActiveSessionManager.shared.liveSession(in: modelContext) : nil
        var experienceID = liveSession?.sharedExperienceID
        do {
            _ = try ProfileScope.$pinned.withValue(recipient.profileID) {
                try DoseLogService.shared.checkedLogBatch(
                    batch, colors: recipient.colors, in: recipient.context,
                    activatesLiveSession: time <= Date.now, schedulesCheckIns: isToday,
                    beforeSave: { entries in
                        QuickLogManager.record(curation, fixedOrder: fixedOrder, context: recipient.context, save: false)
                        if liveSession != nil {
                            let sessions = entries.compactMap(\.session)
                            let sharedID = experienceID ?? sessions.lazy.compactMap(\.sharedExperienceID).first ?? UUID()
                            experienceID = sharedID
                            for session in sessions where session.sharedExperienceID == nil {
                                session.sharedExperienceID = sharedID
                            }
                        }
                    },
                    deferredBookkeeping: {
                        guard isToday else { return }
                        for entry in entries {
                            DoseNotificationManager.doseLogged(entry: entry, recentEntries: recipient.recentEntries)
                        }
                    },
                )
            }
        } catch {
            commitError = .save
            return
        }

        if let liveSession, let experienceID, liveSession.sharedExperienceID == nil {
            liveSession.sharedExperienceID = experienceID
            // The recipient's doses have already committed in their own store.
            // The owner-side link can be saved independently by autosave.
            try? liveSession.modelContext?.save()
        }
        isCommitted = true
        PlatformHaptics.success()
        navigator.dismiss()
    }
}
