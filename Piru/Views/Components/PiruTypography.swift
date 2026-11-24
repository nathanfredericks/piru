import SwiftUI
import UIKit

extension Font {
    static func piru(_ style: Font.TextStyle, design: Font.Design? = nil, weight: Font.Weight? = nil) -> Font {
        let font: Font = design.map { .system(style, design: $0) } ?? .system(style)
        return font.weight(weight ?? (style == .headline ? .semibold : .regular))
    }

    /// A system font at a custom size, scaled relative to a Dynamic Type style.
    static func piru(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design? = nil,
        relativeTo style: Font.TextStyle = .title,
        scaling: Bool = true,
        maximumSize: CGFloat? = nil,
    ) -> Font {
        guard scaling else { return .system(size: size, weight: weight, design: design) }
        let scaled = UIFontMetrics(forTextStyle: style.uiTextStyle).scaledValue(for: size)
        return .system(size: min(scaled, maximumSize ?? scaled), weight: weight, design: design)
    }

    static func piruLabel(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        Font.system(style).weight(weight)
    }
}

private extension Font.TextStyle {
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
}
