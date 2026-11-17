import CoreGraphics

/// The table transcript's scrolls, for the views over it that follow a SwiftUI scroll view's
/// geometry and phase over the stack: Jump to top's reveal and the selection popup. Each sets
/// its own closure as it renders; the table's controller calls them.
@MainActor
final class TranscriptScrollFeed {
  /// Where the viewport's top is, in points below the rows' top, after any move.
  var offsetChanged: (CGFloat) -> Void = { _ in }
  /// Whether the reader is scrolling.
  var scrollPhaseChanged: (Bool) -> Void = { _ in }

  /// The viewport moved to `offset`.
  func moved(to offset: CGFloat) {
    offsetChanged(offset)
  }

  /// The reader started or stopped scrolling.
  func phaseChanged(_ isScrolling: Bool) {
    scrollPhaseChanged(isScrolling)
  }
}
