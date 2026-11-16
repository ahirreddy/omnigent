import Foundation
import Testing

@testable import OmnigentUIComponents

/// A streamed reply is parsed in proportion to what changed: closed blocks are kept and only the
/// open last block is parsed again. The result must equal a parse of the whole text at every
/// step.
@Suite("Streaming markdown parses only the open block")
@MainActor
struct StreamingMarkdownTests {
  static let reply = """
    # Plan

    The refresh path **coalesces** concurrent callers, with `OnceCell` and a [link](https://example.com).
    A second line of the same paragraph.

    Setext heading
    --------------

    1. First step
    2. Second step with *emphasis*

    3. A loose item after a blank line
       continued under the item

    - [x] done
    - [ ] not done
      - nested item

    > A quote
    lazily continued

    > A second quote

    ```swift
    func refresh() async throws {

        let token = try await fetch()
    }
    ```

        indented code
        stays code

    | Column | Value |
    | :----- | ----: |
    | a      | 1     |
    | b      | 2     |

    <div>
    raw html
    </div>

    ***

    Final paragraph with ~~strikethrough~~ and an image ![alt](https://example.com/i.png).
    Title
    =====
    """

  static func chunks(_ text: String, size: Int) -> [String] {
    var prefixes: [String] = []
    var end = text.startIndex
    while end < text.endIndex {
      end = text.index(end, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
      prefixes.append(String(text[..<end]))
    }
    return prefixes
  }

  @Test("blocks equal a whole parse at every step", arguments: [1, 7, 50])
  func blocksMatchWholeParse(chunk: Int) {
    var stream = MarkdownStream(convert: MarkdownParser.blocks)
    for prefix in Self.chunks(Self.reply, size: chunk) {
      #expect(stream.elements(for: prefix) == MarkdownParser.parse(prefix), "\(prefix)")
    }
    #expect(stream.closedCount > 10)
  }

  @Test("Plain tint spans equal a whole parse at every step", arguments: [1, 7, 50])
  func spansMatchWholeParse(chunk: Int) {
    var stream = MarkdownStream(convert: SourceTinting.spans)
    for prefix in Self.chunks(Self.reply, size: chunk) {
      #expect(stream.elements(for: prefix) == SourceTinting.spans(in: prefix), "\(prefix)")
    }
    #expect(stream.closedLength > 0)
  }

  @Test("a link reference definition resolves earlier links, so the text is parsed whole")
  func referenceDefinitionsParseWhole() {
    let text = "See [the docs][docs].\n\nMore text.\n\n[docs]: https://example.com/docs\n"
    var stream = MarkdownStream(convert: MarkdownParser.blocks)
    for prefix in Self.chunks(text, size: 5) {
      #expect(stream.elements(for: prefix) == MarkdownParser.parse(prefix))
    }
    var spans = MarkdownStream(convert: SourceTinting.spans)
    for prefix in Self.chunks(text, size: 5) {
      #expect(spans.elements(for: prefix) == SourceTinting.spans(in: prefix))
    }
  }

  @Test("text that no longer extends the previous text starts over")
  func replacedTextStartsOver() {
    var stream = MarkdownStream(convert: MarkdownParser.blocks)
    _ = stream.elements(for: "First paragraph.\n\nSecond paragraph.\n\nThird\n")
    #expect(stream.closedCount == 2)
    let replaced = "Another reply.\n\n- item\n"
    #expect(stream.elements(for: replaced) == MarkdownParser.parse(replaced))
    #expect(stream.closedCount == 1)
  }

  @Test("text that shrinks or changes before any block closes parses like a whole parse")
  func shrinkingTextBeforeAnyClosedBlock() {
    // Math rewriting makes a growing reply's text shrink: "$$x$$" alone is a fenced block,
    // "$$x$$ is" inline math.
    let steps = ["```math\nx\n```", "`x` is", "`x", "[a]: https://example.com", "[a] b"]
    var stream = MarkdownStream(convert: MarkdownParser.blocks)
    for text in steps {
      #expect(stream.elements(for: text) == MarkdownParser.parse(text), "\(text)")
    }
  }

  @Test("an unfinished line keeps the block before it open: \"3\" becomes the item \"3.\"")
  func unfinishedLineKeepsListOpen() {
    var stream = MarkdownStream(convert: MarkdownParser.blocks)
    _ = stream.elements(for: "1. one\n2. two\n\n3")
    #expect(stream.closedCount == 0)
    let item = "1. one\n2. two\n\n3. three"
    #expect(stream.elements(for: item) == MarkdownParser.parse(item))
    #expect(MarkdownParser.parse(item).count == 1)
  }

  @Test("a view's memo returns the same blocks for the same text and settles from the stream")
  func memoReusesBlocks() {
    let memo = MarkdownRenderMemo()
    let streamed = memo.blocks(for: Self.reply, isStreaming: true)
    #expect(streamed == MarkdownParser.parse(Self.reply))
    #expect(memo.blocks(for: Self.reply, isStreaming: false) == streamed)
  }

  @Test("the bounded cache forgets its oldest entries")
  func boundedCacheEvictsOldest() {
    var cache = BoundedCache<Int, String>(limit: 3)
    var made: [Int] = []
    for key in 0..<10 {
      _ = cache.value(for: key) {
        made.append(key)
        return "\(key)"
      }
    }
    #expect(cache.count == 3)
    _ = cache.value(for: 9) { "again" }
    _ = cache.value(for: 0) {
      made.append(0)
      return "0"
    }
    #expect(made == Array(0..<10) + [0])
  }

  /// `OMNIGENT_BENCH=1 swift test --filter StreamingMarkdownTests/benchmark`: a 20 KB reply in
  /// 50-byte deltas, parsed whole on every delta (before) and through the stream (after).
  @Test(
    "benchmark: 20 KB in 50-byte deltas",
    .enabled(if: ProcessInfo.processInfo.environment["OMNIGENT_BENCH"] != nil))
  func benchmark() {
    var reply = ""
    var section = 0
    while reply.utf8.count < 20_000 {
      section += 1
      reply += Self.reply.replacingOccurrences(of: "# Plan", with: "## Section \(section)")
      reply += "\n\n"
    }
    let prefixes = Self.chunks(reply, size: 50)
    let clock = ContinuousClock()
    let whole = clock.measure {
      for prefix in prefixes { _ = MarkdownParser.parse(prefix) }
    }
    var stream = MarkdownStream(convert: MarkdownParser.blocks)
    let streamed = clock.measure {
      for prefix in prefixes { _ = stream.elements(for: prefix) }
    }
    let wholeTint = clock.measure {
      for prefix in prefixes { _ = SourceTinting.spans(in: prefix) }
    }
    var tints = MarkdownStream(convert: SourceTinting.spans)
    let streamedTint = clock.measure {
      for prefix in prefixes { _ = tints.elements(for: prefix) }
    }
    print(
      "benchmark: \(reply.utf8.count) bytes, \(prefixes.count) deltas; rich whole \(whole), "
        + "streamed \(streamed); plain whole \(wholeTint), streamed \(streamedTint)")
    #expect(streamed < whole)
  }
}
