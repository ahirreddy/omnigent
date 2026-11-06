public import CoreGraphics

/// How the tab overview's grid fills its width, as Safari does: two columns on iPhone, three or
/// four on iPad, each card as wide as its share of the row within a minimum and a maximum.
nonisolated public enum TabGridLayout {
  /// Space around the grid and between its cards.
  public static let spacing: CGFloat = 16
  /// The narrowest a card may get before a row drops a column.
  public static let minimumCardWidth: CGFloat = 240
  /// The widest a card may get; wider windows center the grid.
  public static let maximumCardWidth: CGFloat = 400
  /// Columns kept however narrow or wide the window.
  public static let columnRange: ClosedRange<Int> = 2...4

  /// The number of columns for a grid `width` points wide (padding included).
  /// - Parameter width: The grid's width.
  /// - Returns: Between 2 and 4 columns.
  public static func columns(width: CGFloat) -> Int {
    let usable = width - spacing
    let fitting = Int((usable / (minimumCardWidth + spacing)).rounded(.down))
    return min(columnRange.upperBound, max(columnRange.lowerBound, fitting))
  }

  /// The width each card gets in a grid `width` points wide.
  /// - Parameter width: The grid's width.
  /// - Returns: The card width, at most ``maximumCardWidth``.
  public static func cardWidth(width: CGFloat) -> CGFloat {
    let count = CGFloat(columns(width: width))
    let share = (width - spacing * (count + 1)) / count
    return max(0, min(maximumCardWidth, share))
  }
}
