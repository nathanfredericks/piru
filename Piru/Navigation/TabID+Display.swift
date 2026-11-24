import Foundation

/// Titles and symbols for the fixed tab bar.
extension TabID {
    var title: LocalizedStringResource {
        switch self {
        case let .stock(tab): tab.title
        case .pinned: AppTab.library.title
        }
    }

    var systemImage: String {
        switch self {
        case let .stock(tab): tab.systemImage
        case .pinned: AppTab.library.systemImage
        }
    }
}

extension AppTab {
    var title: LocalizedStringResource {
        switch self {
        case .journal: "Journal"
        case .myMeds: "My Meds"
        case .library: "Library"
        case .tools: "Tools"
        case .insights: "Insights"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .journal: "book"
        case .myMeds: "pills"
        case .library: "books.vertical"
        case .tools: "wrench.and.screwdriver"
        case .insights: "chart.line.uptrend.xyaxis"
        case .search: "magnifyingglass"
        }
    }
}
