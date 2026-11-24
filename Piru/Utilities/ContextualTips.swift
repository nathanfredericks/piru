import SwiftUI
import TipKit

enum ContextualTips {
    static func configure() {
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
        #if DEBUG
            if !UserDefaults.standard.bool(forKey: "piruShowTips") {
                Tips.hideAllTipsForTesting()
            }
        #endif
    }
}

/// One-time hint on a session's timeline graph, replacing the always-on gesture
/// caption. Points out the pan/zoom/inspect gestures the first time a graph is
/// on screen, then retires itself once dismissed.
struct GraphGestureTip: Tip {
    var title: Text {
        Text("Explore the timeline")
    }
    var message: Text? {
        Text("Slide to move, pinch to zoom, and hold to inspect a moment.")
    }
    var image: Image? {
        Image(systemName: "hand.draw")
    }

    /// Shown once, ever.
    var options: [any TipOption] {
        Tips.MaxDisplayCount(1)
    }
}

/// One-time hint on the session's Share button, surfacing that it exports a
/// screenshot, a PDF report, or a Markdown summary — otherwise invisible behind
/// a single icon.
struct ShareSessionTip: Tip {
    var title: Text {
        Text("Share this session")
    }
    var message: Text? {
        Text("Save it as a screenshot, a PDF report, or a Markdown summary.")
    }
    var image: Image? {
        Image(systemName: "square.and.arrow.up")
    }

    /// Shown once, ever.
    var options: [any TipOption] {
        Tips.MaxDisplayCount(1)
    }
}
