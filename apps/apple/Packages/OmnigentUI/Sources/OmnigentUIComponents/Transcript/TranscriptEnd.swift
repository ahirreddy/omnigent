import SwiftUI

/// Where the transcript's scroll view is against its content's end, from the geometry SwiftUI
/// last computed for it. SwiftUI runs a geometry's action once a layout pass, with the first
/// change of that pass: an end left and reached again within one never reaches the action, and
/// what the action last said stays wrong until the next change. The transform that reduces a
/// geometry runs for every one, so what it saw last is where the scroll view is.
nonisolated struct TranscriptEnd: Equatable {
  /// The viewport's bottom against the content's end.
  enum Place: Equatable {
    /// Further than ``ScrollEdgeWatch/reach`` from the end.
    case away
    /// On the bottom row, where a scroll to the end rests: short of the rows' padding.
    case bottomRow
    /// Past the bottom row, at the content's own edge.
    case edge

    /// The place of a viewport whose bottom is at `visibleBottom` of content `contentHeight`
    /// tall.
    @MainActor
    init(visibleBottom: CGFloat, contentHeight: CGFloat) {
      let short = contentHeight - visibleBottom
      // The bottom row rests the rows' padding short of the edge, give or take the reach's slack.
      let padding = Theme.Spacing.extraLarge
      let slack = ScrollEdgeWatch.reach - padding
      if short > padding + slack {
        self = .away
      } else {
        self = short < padding - slack ? .edge : .bottomRow
      }
    }
  }

  /// A transcript opens on its bottom row.
  private(set) var place = Place.bottomRow
  /// Within ``TranscriptViewport/bottomReach`` of the end.
  private(set) var isNearBottom = true
  /// A follower was sent to the end by its edge, and does not rest on the bottom row yet.
  var returnsByEdge = false
  /// A scroll to the bottom row was made that no geometry shows yet: another would land on the
  /// same rows.
  var awaitsLanding = false

  /// Within ``ScrollEdgeWatch/reach`` of the end.
  var isAtEnd: Bool { place != .away }
  /// Off the bottom row, with no scroll there on its way.
  var wantsBottomRow: Bool { place != .bottomRow && !awaitsLanding }

  /// A geometry at `place`.
  /// - Returns: Whether that is news.
  mutating func see(_ place: Place) -> Bool {
    guard self.place != place else { return false }
    self.place = place
    awaitsLanding = false
    return true
  }

  /// A geometry with the viewport's bottom near the end, or away from it.
  /// - Returns: Whether that is news.
  mutating func see(nearBottom isNearBottom: Bool) -> Bool {
    guard self.isNearBottom != isNearBottom else { return false }
    self.isNearBottom = isNearBottom
    return true
  }
}

extension TranscriptScrollState {
  /// SwiftUI computed a scroll geometry at `place`. Its action for a change does not run for
  /// every one, so the turn's end acts on what was seen last.
  func sees(end place: TranscriptEnd.Place) -> TranscriptEnd.Place {
    if end.see(place) { awaitTurnEnd() }
    return place
  }

  /// As ``sees(end:)``, for the viewport's bottom near the end.
  func sees(_ viewport: TranscriptViewport) -> TranscriptViewport {
    if end.see(nearBottom: viewport.isNearBottom) { awaitTurnEnd() }
    return viewport
  }

  /// Tells the follow rules where the bottom was last seen, as a geometry change.
  func settleFollow() {
    guard follow.isNearBottom != end.isNearBottom else { return }
    follow.geometryChanged(isNearBottom: end.isNearBottom)
  }

  /// Rests a return by edge on the bottom row, where every other scroll to the end rests:
  /// the edge itself lies below the rows' padding.
  /// - Returns: Whether there was such a return.
  @discardableResult
  func restOnBottomRow() -> Bool {
    guard end.returnsByEdge else { return false }
    probe("transcript restore", "from the edge to the bottom row")
    leaveEdge()
    end.awaitsLanding = true
    scrollToRow(TranscriptView.bottomID, .bottom)
    awaitTurnEnd()
    return true
  }

  /// Lets go of the edge a return holds: the reader is going elsewhere, or is back.
  func leaveEdge() {
    guard end.returnsByEdge else { return }
    end.returnsByEdge = false
    releaseEnd()
  }
}

/// Lets the scroll state send the scroll view to its content's end by edge, which builds the
/// lazy rows there alone, and let go of that edge again: held, it would keep the scroll view
/// at the end through every later change of the content.
struct EndByEdge: ViewModifier {
  let scroll: TranscriptScrollState
  @State private var position = ScrollPosition()

  func body(content: Content) -> some View {
    scroll.scrollToEnd = { position.scrollTo(edge: .bottom) }
    scroll.releaseEnd = { position = ScrollPosition() }
    return content.scrollPosition($position)
  }
}

/// The viewport's width and whether its bottom is near the content's end, compared together so
/// a width change (rotation, split or sidebar resize) knows where the reader was before it.
nonisolated struct TranscriptViewport: Equatable {
  var width: CGFloat
  var isNearBottom: Bool

  /// How close to the content's end, in points, counts as the bottom.
  static let bottomReach: CGFloat = 80

  /// The viewport of `geometry`; the composer and dock inset the bottom, and rows under them
  /// are not being read.
  init(_ geometry: ScrollGeometry) {
    self.init(
      width: geometry.containerSize.width,
      visibleBottom: geometry.visibleRect.maxY - geometry.contentInsets.bottom,
      contentHeight: geometry.contentSize.height)
  }

  init(width: CGFloat, visibleBottom: CGFloat, contentHeight: CGFloat) {
    self.width = width.rounded()
    isNearBottom = visibleBottom >= contentHeight - Self.bottomReach
  }
}
