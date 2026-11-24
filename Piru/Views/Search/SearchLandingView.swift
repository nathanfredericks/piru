import SwiftData
import SwiftUI

/// The focused-empty state: the recent activity (searches + doses) shown above
/// the keyboard once the field has focus but nothing's typed yet — no browse
/// cards (they'd read oddly under the keyboard).
struct SearchActivityList: View {
    @State private var activity = SearchActivityModel()
    @State private var history = SearchHistoryStore.shared
    @Query(SearchActivityModel.recentDoses(limit: Self.doseLimit)) private var recentEntries: [DoseEntry]

    private static let doseLimit = 8

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                RecentActivityGroups(activity: activity, history: history)
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.top, Spacing.md)
            .padding(.bottom, 28)
        }
        .task(id: history.recent) { await activity.loadSearched(history.recent) }
        .task(id: DoseLogService.shared.revision) { await activity.loadTaken(from: recentEntries, limit: Self.doseLimit) }
    }
}

// MARK: - Recent activity

/// What the two recent groups show, resolved off the warm substance cache.
///
/// Loaded from a `.task` on the screen's `ScrollView`, never on the groups
/// themselves: a group with nothing to show is an empty view, SwiftUI attaches
/// no task to an empty view, and a task that is the only thing able to make the
/// group non-empty then never runs — the screen stays blank forever.
@Observable
@MainActor
final class SearchActivityModel {
    /// Substances tapped from past searches, most recent first. Stale names
    /// that no longer resolve are dropped.
    private(set) var searched: [Substance] = []
    /// The most recently taken substances from the dose log.
    private(set) var taken: [Substance] = []

    /// Bounded: enough rows to surface `limit` distinct substances even with
    /// repeats, without faulting the entire dose log on the focus transition.
    static func recentDoses(limit: Int) -> FetchDescriptor<DoseEntry> {
        var descriptor = FetchDescriptor<DoseEntry>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = max(limit * 15, 90)
        descriptor.propertiesToFetch = [\.substance]
        return descriptor
    }

    func loadSearched(_ names: [String]) async {
        guard !names.isEmpty else {
            searched = []
            return
        }
        await SubstanceStore.shared.ensureAllLoaded()
        // Warm batch cache, not the heavy ~21-query resolve — the row only
        // renders name/category/subtitle/isStub, all on the projection.
        searched = names.compactMap { SubstanceLibrary.lookup($0) }
    }

    func loadTaken(from entries: [DoseEntry], limit: Int) async {
        await SubstanceStore.shared.ensureAllLoaded()
        var seen = Set<String>()
        var result: [Substance] = []
        for entry in entries {
            let key = entry.substance.lowercased()
            if seen.insert(key).inserted, let substance = SubstanceLibrary.lookup(key) {
                result.append(substance)
                if result.count >= limit { break }
            }
        }
        taken = result
    }
}

/// "Recently Searched" (with Clear) and "Recent", each only when it has rows.
private struct RecentActivityGroups: View {
    let activity: SearchActivityModel
    let history: SearchHistoryStore

    var body: some View {
        if !activity.searched.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack {
                    SectionLabel("Recently Searched")
                    Spacer()
                    Button("Clear") { history.clear() }
                        .sectionLabel()
                }
                .padding(.horizontal, Spacing.xs)
                SubstanceRowsCard(substances: activity.searched)
            }
        }
        if !activity.taken.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.md) {
                SectionLabel("Recent").padding(.horizontal, Spacing.xs)
                SubstanceRowsCard(substances: activity.taken)
            }
        }
    }
}

/// A grouped rounded card of substance rows with hairline dividers — the
/// grouped-list look at the library's 16pt gutter (an inset-grouped `List`
/// section would over-inset it). Each row pushes the substance detail.
private struct SubstanceRowsCard: View {
    let substances: [Substance]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(substances.enumerated()), id: \.element.id) { index, substance in
                if index > 0 {
                    Divider().padding(.leading, Spacing.xxl)
                }
                RouteLink(PushRoute.substance(name: substance.name)) {
                    HStack(spacing: Spacing.md) {
                        SubstanceRowView(substance: substance, isPersonalized: CustomSubstanceStore.shared.isPersonalized(substance.name))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.secondaryLabel)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .themeCard(cornerRadius: Theme.CornerRadius.container)
    }
}

private struct SectionLabel: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) {
        self.title = title
    }
    var body: some View {
        Text(title)
            .sectionLabel()
            .foregroundStyle(Theme.secondaryLabel)
            .accessibilityAddTraits(.isHeader)
    }
}
