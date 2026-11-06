import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("Markdown caches and warm-up")
@MainActor
struct MarkdownWarmupTests {
  /// A reply unique to the test run, so the shared caches start without it.
  private static func reply(_ name: String) -> String {
    "# \(name) \(UUID().uuidString)\n\nSome *prose*.\n\n```swift\nlet value = \"\(name)\"\n```\n"
  }

  @Test("the markdown cache parses once and answers from any thread")
  func cacheIsShared() async {
    let cache = MarkdownCache(limit: 8)
    let text = Self.reply("shared")
    #expect(!cache.contains(text))
    let parsed = await Task.detached { cache.blocks(for: text) }.value
    #expect(parsed == MarkdownParser.parse(text))
    #expect(cache.contains(text))
    #expect(cache.blocks(for: text) == parsed)
  }

  @Test("the markdown cache forgets its oldest text past its limit")
  func cacheIsBounded() {
    let cache = MarkdownCache(limit: 2)
    let texts = (0..<3).map { "Paragraph \($0)." }
    for text in texts { _ = cache.blocks(for: text) }
    #expect(!cache.contains(texts[0]))
    #expect(cache.contains(texts[2]))
  }

  @Test("code spans are cached by code and fence name")
  func codeSpans() {
    let cache = CodeSpanCache(limit: 4)
    let code = "let x = \"y\" // z"
    let spans = cache.spans(code, language: "swift")
    #expect(spans == CodeHighlighting.spans(code, language: "swift"))
    #expect(cache.spans(code, language: "Swift extra") == spans)
    #expect(cache.spans(code, language: "text").isEmpty)
  }

  @Test("coloring spans colors exactly their text and keeps the rest plain")
  func coloringIsExact() {
    let code = "é let x = 1\n// 🙂 note\n"
    let spans = CodeHighlighting.spans(code, language: "swift")
    #expect(!spans.isEmpty)
    let colored = CodeHighlighting.attributed(code, spans: spans) { _ in .red }
    #expect(String(colored.characters) == code)
    let red = colored.runs.filter { $0.foregroundColor == .red }
      .map { String(colored[$0.range].characters) }
    let utf16 = Array(code.utf16)
    let expected = spans.map { String(decoding: utf16[$0.range], as: UTF16.self) }
    #expect(red == expected)
  }

  @Test("overlapping or out-of-range spans are skipped, not misplaced")
  func coloringSkipsBadSpans() {
    let code = "abcdef"
    let spans = [
      CodeSpan(token: .inserted, range: 0..<2), CodeSpan(token: .deleted, range: 1..<3),
      CodeSpan(token: .header, range: 4..<6), CodeSpan(token: .header, range: 5..<40),
    ]
    let colored = CodeHighlighting.attributed(code, spans: spans) { token in
      token == .inserted ? .green : .blue
    }
    #expect(String(colored.characters) == code)
    let colors = colored.runs.map { (String(colored[$0.range].characters), $0.foregroundColor) }
    #expect(colors.map(\.0) == ["ab", "cd", "ef"])
    #expect(colors.map(\.1) == [.green, nil, .blue])
  }

  @Test("warm-up prepares settled answers newest first and hands each text over once")
  func warmupPreparesSettledAnswers() async {
    let older = Self.reply("older")
    let newer = Self.reply("newer")
    let streaming = Self.reply("streaming")
    let warmup = MarkdownWarmup()
    var rows = [
      Row(id: "u1", role: .user, text: "Question"),
      Row(id: "a1", role: .assistant, text: older),
      Row(id: "a2", role: .assistant, text: newer),
      Row(id: "a3", role: .assistant, text: streaming, isStreaming: true),
    ]
    #expect(warmup.warm(rows) != nil)
    #expect(warmup.handedCount == 2)
    await warmup.settle()
    #expect(MarkdownCache.shared.contains(older))
    #expect(MarkdownCache.shared.contains(newer))
    #expect(!MarkdownCache.shared.contains(streaming))
    #expect(CodeSpanCache.shared.contains("let value = \"newer\"", language: "swift"))

    #expect(warmup.warm(rows) == nil, "nothing new to hand over")
    #expect(warmup.handedCount == 2)
    rows[3].isStreaming = false
    warmup.warm(rows)
    #expect(warmup.handedCount == 3)
    await warmup.settle()
    #expect(MarkdownCache.shared.contains(streaming))
  }

  @Test("an older page landing above is scanned whole")
  func warmupScansPrependedPages() {
    let warmup = MarkdownWarmup()
    let latest = [Row(id: "a9", role: .assistant, text: Self.reply("latest"))]
    warmup.warm(latest)
    let page = (0..<6).map { Row(id: "a\($0)", role: .assistant, text: Self.reply("page \($0)")) }
    warmup.warm(page + latest)
    #expect(warmup.handedCount == 7)
  }
}
