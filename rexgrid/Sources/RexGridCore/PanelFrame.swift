import CoreGraphics
import Foundation

/// Where the panel goes when its content changes height.
///
/// Rectangles use AppKit's screen coordinates: the origin is the bottom-left
/// corner and y grows upward, so a window's top edge is `maxY`.
public enum PanelFrame {
    /// The frame that fits `contentHeight`, keeping the width and left edge.
    ///
    /// The top edge stays where it is, so the panel grows and shrinks
    /// downward and a cell near the top doesn't move under the pointer. The
    /// panel slides up only when its bottom would leave `visible`, and is
    /// never taller than `visible`; content beyond that scrolls.
    public static func fitting(
        current: CGRect,
        contentHeight: CGFloat,
        visible: CGRect,
        minimumHeight: CGFloat
    ) -> CGRect {
        let height = max(minimumHeight, min(contentHeight.rounded(.up), visible.height))
        let y = max(current.maxY - height, visible.minY)
        return CGRect(x: current.minX, y: y, width: current.width, height: height)
    }
}

/// The grid's dimensions, and what follows from them.
///
/// The view lays its cells out with these numbers and the panel sizes itself
/// with them, so the two can't disagree about how many rows there are.
public struct GridMetrics: Sendable, Equatable {
    /// A cell is at least this wide; a row holds as many as fit.
    public var cellMinimumWidth: CGFloat = 230
    public var cellHeight: CGFloat = 122
    /// Between cells, both across and down.
    public var spacing: CGFloat = 8

    public static let standard = GridMetrics()

    public init() {}

    /// How many cells fit side by side in `width`. Never fewer than one.
    public func columns(fitting width: CGFloat) -> Int {
        max(1, Int((width + spacing) / (cellMinimumWidth + spacing)))
    }

    /// The height of `cells` cells laid out `columns` to a row.
    public func height(cells: Int, columns: Int) -> CGFloat {
        guard cells > 0 else { return 0 }
        let rows = (cells + max(1, columns) - 1) / max(1, columns)
        return CGFloat(rows) * cellHeight + CGFloat(rows - 1) * spacing
    }
}
