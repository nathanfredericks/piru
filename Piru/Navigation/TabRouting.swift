/// Resolves destinations saved by earlier builds onto the fixed tab bar.
nonisolated enum TabRouting {
    static func destination(for tab: TabID, path: [PushRoute]) -> (tab: TabID, path: [PushRoute]) {
        switch tab {
        case .stock(.tools):
            (.library, [.toolsHub] + path)
        case .stock(.search):
            (.library, path)
        case let .pinned(screen):
            switch screen {
            case .tool:
                (.library, [.toolsHub, screen.route] + path)
            case .insight, .insightGroup:
                (.insights, [screen.route] + path)
            case .myMeds:
                (.myMeds, path)
            case .timeline:
                (.journal, [screen.route] + path)
            case .dataStorage:
                (.library, [screen.route] + path)
            }
        case .stock:
            (tab, path)
        }
    }
}
