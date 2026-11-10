import SwiftUI

/// The row under the transcript viewport's middle and how far down the row that middle is. A
/// resize scrolls that point of the row back to the viewport's middle, so what the reader was
/// looking at stays there however the rows above it reflow.
nonisolated struct TranscriptReadingAnchor: Equatable {
  var id: String
  /// The middle's position in the row, 0 at its top and 1 at its bottom.
  var fraction: Double
  var rowHeight: CGFloat
  var viewportWidth: CGFloat
  var viewportHeight: CGFloat

  /// The anchor for a row of `height` when the viewport (in the row's coordinates) crosses it
  /// at its middle; `nil` otherwise.
  static func sample(id: String, height: CGFloat, viewport: CGRect?) -> Self? {
    guard let viewport, height > 0 else { return nil }
    let middle = viewport.midY
    guard middle >= 0, middle < height else { return nil }
    return Self(
      id: id, fraction: (middle / height * 200).rounded() / 200, rowHeight: height.rounded(),
      viewportWidth: viewport.width.rounded(), viewportHeight: viewport.height.rounded())
  }

  /// The `scrollTo` anchor that puts this anchor's point of the row at the viewport's middle,
  /// given the row and viewport sizes in `layout`. `scrollTo(_:anchor:)` lines up the same unit
  /// point of the row and of the viewport, so the anchor solves
  /// `y * (viewport - row) + fraction * row = viewport / 2`.
  func unitPoint(in layout: Self) -> UnitPoint {
    let row = layout.rowHeight
    let viewport = layout.viewportHeight
    guard abs(viewport - row) >= 1 else { return UnitPoint(x: 0.5, y: fraction) }
    return UnitPoint(x: 0.5, y: (viewport / 2 - fraction * row) / (viewport - row))
  }
}

extension TranscriptReadingAnchor {
  /// The row to scroll to for `wanted` after a scroll to it put `landed` under the viewport's
  /// middle: as far from `wanted` in `order` as `landed`, on its other side. A scroll to a row
  /// not laid out goes by estimate, and one that missed misses the same way again.
  static func counterTarget(wanted: String, landed: String, in order: [String]) -> String? {
    guard wanted != landed, let wantedIndex = order.firstIndex(of: wanted),
      let landedIndex = order.firstIndex(of: landed)
    else { return nil }
    return order[min(max(2 * wantedIndex - landedIndex, 0), order.count - 1)]
  }
}

extension View {
  /// Reports this transcript row as the reading anchor while it crosses the viewport's middle.
  func reportsReadingAnchor(_ id: String) -> some View {
    modifier(ReadingAnchorReporter(id: id))
  }
}

private struct ReadingAnchorReporter: ViewModifier {
  let id: String
  @Environment(\.transcriptScrollState) private var scroll

  func body(content: Content) -> some View {
    content.onGeometryChange(for: TranscriptReadingAnchor?.self) { [id] proxy in
      TranscriptReadingAnchor.sample(
        id: id, height: proxy.size.height, viewport: proxy.bounds(of: .scrollView))
    } action: { sample in
      if let sample { scroll?.record(sample) }
    }
  }
}
