import Foundation

/// A settled turn's tool work as CLI text, as ``CLIWorkGroup`` and ``CLIToolLines`` draw it:
/// its cells a block gap apart, each a `•` line with what it left on the `└` branch.
nonisolated struct CLIWorkSpec: Hashable, Sendable {
  var cells: [CLIWorkCell]
}

/// One cell of tool work: a tool call's line, an "Explored" line, a reasoning line or a
/// collapsed group's summary, and its details.
nonisolated struct CLIWorkCell: Hashable, Sendable {
  /// What the reader acts on in the cell: a tool call, an activity or the group, by id.
  var id: String
  var line: CLILineText
  /// The marker's color; `nil` for the bullet's.
  var marker: SRGB?
  var glyph = CLIBullet.glyph
  var details: [CLIWorkDetail] = []
  /// The space between the line and each of its details.
  var gap = Gap.lineSpacing

  /// A tool call's details sit a line spacing apart; an activity's a small gap.
  enum Gap: Hashable, Sendable {
    case lineSpacing
    case small
  }
}

/// What a cell shows under its line.
nonisolated enum CLIWorkDetail: Hashable, Sendable {
  /// `└ ` then text, its first `limit` lines unless `showsAll`, then "… +N lines", which
  /// `action` opens; `indent` characters in.
  case tree(CLIWorkTree)
  /// A command's lines after its first, each behind `│ `, past `limit` how many more.
  case commandLines([String], limit: Int, showsAll: Bool, action: String)
  /// An edit's files and their first `limit` changed lines, then how many more.
  case diff([CLIDiffFile], limit: Int, action: String)
  /// A plan update's note and steps.
  case plan(note: String?, steps: [CLIPlanStep])
  /// One line under "Explored", `id` its own, and its calls' output once opened.
  case branch(CLILineText, isFirst: Bool, id: String, trees: [CLIWorkTree])
}

/// Text on the `└` branch (``CLIOutputTree``).
nonisolated struct CLIWorkTree: Hashable, Sendable {
  var text: String
  var color: SRGB
  var limit: Int
  var showsAll: Bool
  /// What "… +N lines" opens.
  var action: String
  /// Characters in from the cell's column.
  var indent = 0
}

/// The work the reader opened or closed, by id: a tool call's output, an explored line's, an
/// activity's details, a group collapsed. A cell showing other rows once it scrolls away, the
/// choice lives with the table. ``serial`` rises with each change.
@MainActor
final class CLIWorkExpansions {
  private(set) var opened: Set<String> = []
  private(set) var collapsed: Set<String> = []
  private(set) var serial = 0

  func isOpen(_ id: String) -> Bool { opened.contains(id) }

  func isCollapsed(_ id: String) -> Bool { collapsed.contains(id) }

  func toggle(_ id: String) {
    if opened.remove(id) == nil { opened.insert(id) }
    serial += 1
  }

  func toggleCollapsed(_ id: String) {
    if collapsed.remove(id) == nil { collapsed.insert(id) }
    serial += 1
  }
}
