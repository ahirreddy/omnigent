import Foundation

/// What a CLI text cell draws: agent output in Plain or Styled rendering, a user's prompt, the
/// dim line under a settled turn, or a turn's tool work.
nonisolated enum CLITextSpec: Hashable, Sendable {
  case styled(String)
  case plain(String)
  case prompt(String)
  case footer(String)
  case work(CLIWorkSpec)

  /// The spec as one string, for the prewarm's queue; tool work goes by its hash, which the
  /// prewarm looks up (``CLITextPrewarm``).
  var key: String {
    switch self {
    case .styled(let text): "s\u{1}" + text
    case .plain(let text): "p\u{1}" + text
    case .prompt(let text): "u\u{1}" + text
    case .footer(let text): "f\u{1}" + text
    case .work(let work): "w\u{1}\(work.hashValue)"
    }
  }

  init?(key: String) {
    guard let separator = key.firstIndex(of: "\u{1}") else { return nil }
    let text = String(key[key.index(after: separator)...])
    switch key[..<separator] {
    case "s": self = .styled(text)
    case "p": self = .plain(text)
    case "u": self = .prompt(text)
    case "f": self = .footer(text)
    default: return nil
    }
  }
}

/// One leaf text of a CLI block, as SwiftUI lays it out (one `Text`): its characters in the
/// built text, and the space its frame keeps above and below its lines (a table row's padding).
nonisolated struct CLITextUnit: Sendable {
  var range: NSRange
  var padTop: CGFloat = 0
  var padBottom: CGFloat = 0
}

/// How SwiftUI stacks a CLI block's texts (``CLIBlocks``, ``CLIListLayout``, ``CLIQuoteView``,
/// a table's grid, a prompt's runs): the layout reads each text's top from it, once TextKit has
/// counted the text's lines.
nonisolated indirect enum CLITextNode: Sendable {
  /// One text, by its unit's index.
  case text(Int)
  /// A stack of nodes, each with the gap above it.
  case stack([CLITextStackItem])
  /// A list's items: a line spacing apart, or a blank line once one is taller than `threshold`.
  case list(items: [Self], compact: CGFloat, loose: CGFloat, threshold: CGFloat)
  /// A quote, with its column of `>` markers at `markerX`.
  case quote(Self, markerX: CGFloat, color: SRGB)
  /// A table's rows, the rule under each, and its columns.
  case table(rows: [Int], rules: [CGFloat], columns: [CLITextColumn], color: SRGB)
  /// A prompt's quoted run, with the bar at `leading` beside it.
  case bar(Self, leading: CGFloat, color: SRGB)
  /// A text whose first line has `glyph` hanging in the gutter before it.
  case marked(Self, glyph: String, color: SRGB)
  /// A node the reader acts on, by `id`: its frame across the text's width.
  case region(Self, id: String)
  /// A node on a band of `color` from `leading` across the text's width.
  case background(Self, leading: CGFloat, color: SRGB, opacity: Double)
}

/// A node in a stack and the gap above it.
nonisolated struct CLITextStackItem: Sendable {
  var gap: CGFloat
  var node: CLITextNode
}

/// A table column's leading edge and width, its padding included.
nonisolated struct CLITextColumn: Sendable {
  var leading: CGFloat
  var width: CGFloat
}

/// A CLI block built as one attributed string, its texts and how they stack.
nonisolated struct CLITextBuild: @unchecked Sendable {
  var text: NSAttributedString
  var units: [CLITextUnit]
  var root: CLITextNode
  /// What each region reads as, by its id: a tool work line's text, or "… +N lines".
  var labels: [String: String] = [:]
}

nonisolated extension NSAttributedString {
  /// The range of the paragraph starting at `location`, its line break included: the text's
  /// paragraphs end at line breaks only.
  func paragraph(startingAt location: Int) -> NSRange {
    let utf16 = string.utf16
    guard location < utf16.count else { return NSRange(location: location, length: 0) }
    let start = utf16.index(utf16.startIndex, offsetBy: location)
    let end = utf16[start...].firstIndex(of: 0x0A).map { utf16.index(after: $0) } ?? utf16.endIndex
    return NSRange(location: location, length: utf16.distance(from: start, to: end))
  }
}
