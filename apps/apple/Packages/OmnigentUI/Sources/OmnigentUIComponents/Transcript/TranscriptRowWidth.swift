import SwiftUI

/// The width the transcript's rows are laid out at. Lazy rows that change width below the
/// conversation's start are built one by one, from the row that was in view to whatever lies
/// at the old offset once the rows above are estimated again: hundreds in a long conversation.
/// Held, they take a new width while the scroll view is at its top, where no row lies above,
/// and the reader is put back within the same layout pass (``Passage``).
@MainActor
@Observable
final class TranscriptRowWidth {
  /// The scroll view's trip to the top for the rows' new width, and where the reader was.
  struct Passage: Equatable {
    /// The row to put back at the viewport's middle; `nil` for a reader at the end.
    var anchor: TranscriptReadingAnchor?
    /// The row the reader jumped to on the way, whose top the passage ends at instead.
    private(set) var jump: String?
    /// The rows have the new width; before that the scroll view is on its way to the top.
    var hasWidth = false
    /// Scrolls to the top left for one the scroll view did not follow.
    var topScrollsLeft = 2

    /// The reader jumped to `target` on the way. A jump to `end` ends as a follower's passage.
    mutating func jump(to target: String, end: String) {
      anchor = nil
      jump = target == end ? nil : target
    }

    /// Whether the scroll view, short of the top, is sent there again.
    mutating func takesTopScroll() -> Bool {
      guard !hasWidth, topScrollsLeft > 0 else { return false }
      topScrollsLeft -= 1
      return true
    }
  }

  /// The rows' width; `nil` before the viewport's first report, when they take what they get.
  private(set) var held: CGFloat?
  /// The viewport's latest width.
  @ObservationIgnored private var offered: CGFloat?
  @ObservationIgnored var passage: Passage?

  /// The rows are at another width than the viewport's.
  var isBehind: Bool { held != offered }

  /// The viewport reports its width.
  /// - Returns: Whether the rows are now at another width.
  func offer(_ width: CGFloat) -> Bool {
    offered = width
    if held == nil { held = width }
    return isBehind
  }

  /// Gives the rows the viewport's width.
  func catchUp() {
    if isBehind { held = offered }
  }
}

/// Lays the transcript's rows out at their held width in the column they are offered, and
/// reports that column's width and the rows taking a new one.
struct HeldRowWidth: ViewModifier {
  @Environment(\.transcriptScrollState) private var scroll

  func body(content: Content) -> some View {
    content
      .frame(width: scroll?.rowWidth.held)
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.width
      } action: { _ in
        scroll?.rowsResized()
      }
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.width
      } action: { width in
        scroll?.rowWidthOffered(width)
      }
  }
}

/// Tells the scroll state when the transcript's scroll view reaches and leaves its top and
/// its end.
struct ScrollEdgeWatch: ViewModifier {
  let scroll: TranscriptScrollState

  /// How far from an edge counts as there: a scroll to the first or last row stops short of
  /// the rows' padding.
  static let reach = Theme.Spacing.extraLarge + 2

  func body(content: Content) -> some View {
    content
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.contentOffset.y + geometry.contentInsets.top <= Self.reach
      } action: { _, isAtTop in
        scroll.topReached(isAtTop)
      }
      .onScrollGeometryChange(for: Bool.self) { geometry in
        let visibleBottom = geometry.visibleRect.maxY - geometry.contentInsets.bottom
        return visibleBottom >= geometry.contentSize.height - Self.reach
      } action: { _, isAtEnd in
        scroll.endReached(isAtEnd)
      }
  }
}
