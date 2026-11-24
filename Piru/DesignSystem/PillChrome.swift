import SwiftUI

extension View {
    /// Applies the standard fill and label color to a custom action.
    func prominentActionFill(in shape: some Shape) -> some View {
        foregroundStyle(Color.white)
            .background(Theme.accent, in: shape)
    }
}

extension Text {
    func filledChip(text: Color, fill: Color, style: Font.TextStyle, weight: Font.Weight, horizontal: CGFloat, vertical: CGFloat) -> some View {
        font(.piruLabel(style, weight: weight))
            .lineLimit(1)
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background(fill.opacity(Theme.Opacity.tint), in: Capsule())
            .foregroundStyle(text)
    }

    func outlineChip(stroke: Color, style: Font.TextStyle, weight: Font.Weight, horizontal: CGFloat, vertical: CGFloat) -> some View {
        font(.piruLabel(style, weight: weight))
            .lineLimit(1)
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .foregroundStyle(Theme.secondaryLabel)
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
    }
}
