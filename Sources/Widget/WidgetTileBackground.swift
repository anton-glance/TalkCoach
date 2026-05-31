import AppKit
import SwiftUI

// MARK: - Tile background helper

// Applies Liquid Glass material (glass mode) or a solid neutral fill with inner shadow
// (reduce-transparency mode) as the tile background. Both branches clip the content to the
// same RoundedRectangle so the glass shape and the visible boundary are aligned.
//
// Glass branch: .clipShape clips the ZStack content, then .glassEffect(.regular, in: shape)
// renders the Liquid Glass material behind the clipped content. Both use the same shape, so
// glass and content clip are visually aligned.
//
// Solid branch: .background fills behind the ZStack content with a system window background
// colour (adapts light/dark automatically) plus a ShapeStyle inner shadow for depth without
// translucency. .clipShape clips everything to the tile boundary.
//
// Note: .glassEffect does NOT automatically adapt to accessibilityDisplayShouldReduceTransparency.
// This branching is the required manual fallback.
extension View {
    @ViewBuilder
    func widgetTileBackground(reduceTransparency: Bool) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: DesignTokens.Layout.cornerRadius, style: .continuous
        )
        if reduceTransparency {
            self
                .background(
                    shape.fill(
                        Color(NSColor.windowBackgroundColor)
                            .shadow(.inner(color: .black.opacity(0.10), radius: 3, x: 0, y: 2))
                    )
                )
                .clipShape(shape)
        } else {
            self
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
        }
    }
}
