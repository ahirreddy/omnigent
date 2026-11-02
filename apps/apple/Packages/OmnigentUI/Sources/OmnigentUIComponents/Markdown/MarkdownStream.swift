import Foundation
import Markdown

/// Parses markdown that grows at its end (a streamed reply) in proportion to what changed.
///
/// CommonMark parses blocks line by line and never reopens a block it closed on a complete line,
/// so every top-level block before the last one is final once the line that started the next
/// block is complete. (An unfinished line can still change: "3" becomes the list item "3.".)
/// Those blocks are converted once, and each update parses only from where the open blocks
/// start. The result equals a parse of the whole text, with one exception handled by parsing
/// whole: link reference definitions and footnotes resolve across the whole document.
nonisolated struct MarkdownStream<Element> {
  /// Converts top-level blocks parsed from `source`, which starts at UTF-8 offset `base` of the
  /// whole text.
  typealias Convert = (_ blocks: [any Markup], _ source: Substring, _ base: Int) -> [Element]

  private let convert: Convert
  private var closedSource = ""
  private var closed: [Element] = []
  private var scanned = 0
  private var hasDefinitions = false

  /// Creates a stream.
  /// - Parameter convert: Converts parsed top-level blocks to the output.
  init(convert: @escaping Convert) {
    self.convert = convert
  }

  /// The UTF-8 offset where the open block starts.
  var closedLength: Int { closedSource.utf8.count }

  /// How many leading elements belong to closed blocks.
  var closedCount: Int { closed.count }

  /// The output for `text`, reusing the closed blocks of the previous text when `text` extends
  /// it.
  /// - Parameter text: The whole text so far.
  /// - Returns: What a parse of the whole text would give.
  mutating func elements(for text: String) -> [Element] {
    if !text.utf8.starts(with: closedSource.utf8) { reset() }
    scanForDefinitions(text)
    if hasDefinitions {
      return convert(Self.topLevelBlocks(text), text[...], 0)
    }
    let utf8 = text.utf8
    let base = closedLength
    let tail = text[utf8.index(utf8.startIndex, offsetBy: base)...]
    let blocks = Self.topLevelBlocks(String(tail))
    guard let last = blocks.last else { return closed }
    var open = blocks
    // The last block's line may be unfinished; then the block before it stays open too.
    var split = blocks.count - 1
    var start = Self.lineStart(of: last, in: tail)
    if let lineStart = start, !Self.hasNewline(in: tail, after: lineStart) {
      split -= 1
      start = split > 0 ? Self.lineStart(of: blocks[split], in: tail) : nil
    }
    if split > 0, let start {
      let end = tail.utf8.index(tail.startIndex, offsetBy: start)
      closed += convert(Array(blocks[..<split]), tail[..<end], base)
      closedSource = String(text[..<end])
      open = Array(blocks[split...])
    }
    return closed + convert(open, tail, base)
  }

  private mutating func reset() {
    closedSource = ""
    closed = []
    scanned = 0
    hasDefinitions = false
  }

  /// Notes a `]:` (a link reference definition or footnote) in the text not scanned yet.
  private mutating func scanForDefinitions(_ text: String) {
    guard !hasDefinitions else { return }
    let utf8 = text.utf8
    var previous: UInt8 = 0
    var index = utf8.index(utf8.startIndex, offsetBy: max(scanned - 1, 0))
    while index < utf8.endIndex {
      let byte = utf8[index]
      if previous == UInt8(ascii: "]"), byte == UInt8(ascii: ":") {
        hasDefinitions = true
        return
      }
      previous = byte
      utf8.formIndex(after: &index)
    }
    scanned = utf8.count
  }

  static func topLevelBlocks(_ text: String) -> [any Markup] {
    Array(Document(parsing: text, options: [.disableSmartOpts]).children)
  }

  private static func hasNewline(in source: Substring, after offset: Int) -> Bool {
    source.utf8.dropFirst(offset).contains(UInt8(ascii: "\n"))
  }

  /// The UTF-8 offset in `source` of the line where `block` starts.
  private static func lineStart(of block: any Markup, in source: Substring) -> Int? {
    guard let line = block.range?.lowerBound.line, line > 1 else { return nil }
    var remaining = line - 1
    var offset = 0
    for byte in source.utf8 {
      offset += 1
      if byte == UInt8(ascii: "\n") {
        remaining -= 1
        if remaining == 0 { return offset }
      }
    }
    return nil
  }
}
