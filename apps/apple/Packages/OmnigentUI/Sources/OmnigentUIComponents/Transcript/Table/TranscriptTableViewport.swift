import Observation
import SwiftUI

/// Where the table transcript's viewport is over its last row, which holds the inline request
/// cards: no SwiftUI scroll view reaches into the table's cells, so a card asks this to tell
/// whether it is on screen (``InlineDecisionVisibility``).
@MainActor
@Observable
final class TranscriptTableViewport {
  /// The coordinate space of a table cell, whose origin is its row's top.
  static let cellSpace = "transcript-table-cell"

  /// The part of the viewport the bars leave the rows, in the last row's coordinates; `nil`
  /// before the table has laid it out.
  private(set) var footer: CGRect?

  /// Records the viewport over the last row; a move of under half a point changes nothing.
  func setFooter(_ rect: CGRect?) {
    guard let rect else {
      if footer != nil { footer = nil }
      return
    }
    if let footer, abs(footer.minY - rect.minY) < 0.5, abs(footer.height - rect.height) < 0.5,
      abs(footer.width - rect.width) < 0.5
    {
      return
    }
    footer = rect
  }
}

extension EnvironmentValues {
  /// The table transcript's viewport over its rows; `nil` in the stack, whose cards read their
  /// scroll view's bounds.
  @Entry var transcriptTableViewport: TranscriptTableViewport?
}
