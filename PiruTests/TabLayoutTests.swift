import Foundation
import Testing
@testable import Piru

private func makeIsolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "FixedTabsTests-\(UUID().uuidString)")!
}

@MainActor
@Suite("Fixed tabs and legacy navigation")
struct FixedTabsTests {
    @Test
    func `Only the four fixed destinations are tab items`() {
        #expect(TabID.visible == [.journal, .myMeds, .library, .insights])
    }

    @Test(arguments: ["tools", "search", "tool.inventory", "insight.reports", "myMeds", "timeline", "dataStorage"])
    func `Every legacy tab key still decodes`(key: String) throws {
        let data = try JSONEncoder().encode(key)
        let tab = try JSONDecoder().decode(TabID.self, from: data)
        #expect(tab.storageKey == key)
    }

    @Test
    func `A saved tool pin restores the tool under the Library hub`() {
        let storage = makeIsolatedDefaults()
        storage.set("tool.inventory", forKey: "AppNavigator.selectedTab")

        let navigator = AppNavigator(storage: storage)

        #expect(navigator.selectedTab == .library)
        #expect(navigator.path(for: .library) == [.toolsHub, .tool(.inventory)])
    }

    @Test
    func `Old Tools and Search links both open the Library workflow they name`() throws {
        let navigator = AppNavigator(storage: makeIsolatedDefaults())
        let tools = try #require(URL(string: "piru://tools").flatMap(DeepLink.decode))
        let search = try #require(URL(string: "piru://search").flatMap(DeepLink.decode))

        navigator.apply(tools)
        #expect(navigator.selectedTab == .library)
        #expect(navigator.path(for: .library) == [.toolsHub])
        #expect(navigator.librarySearchRequest == nil)

        navigator.apply(search)
        #expect(navigator.selectedTab == .library)
        #expect(navigator.path(for: .library).isEmpty)
        #expect(navigator.takeLibrarySearchRequest() == "")
        #expect(navigator.takeLibrarySearchRequest() == nil)
    }

    @Test
    func `Old snapshots keep usable sheets and Tools paths`() throws {
        let data = Data(#"{"selectedTab":"tools","paths":{"tools":[{"tool":{"_0":"inventory"}}]},"sheetStack":[{"onboarding":{}},{"skins":{}},{"quickLog":{"routine":"morning"}}]}"#.utf8)
        let snapshot = try JSONDecoder().decode(NavigatorSnapshot.self, from: data)
        let navigator = AppNavigator(storage: makeIsolatedDefaults())
        navigator.snapshot = snapshot

        #expect(navigator.selectedTab == .library)
        #expect(navigator.path(for: .library) == [.toolsHub, .tool(.inventory)])
        #expect(navigator.sheetStack == [.settings, .quickLog(routine: "morning")])
    }

    @Test
    func `A date only Quick Log link round trips`() throws {
        let date = Date(timeIntervalSince1970: 1_795_392_000)
        let route = SheetRoute.quickLog(routine: nil, prefillDate: date)
        let url = try #require(DeepLink.encode(NavigatorSnapshot(sheetStack: [route])))

        #expect(DeepLink.decode(url)?.sheet == route)
    }
}
