import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("CLI style: the pieces of terminal markdown")
struct CLIMarkdownPieceTests {
  @Test("a list's items sit a blank line apart once one of them wraps")
  func listSpacing() {
    let layout = CLIListLayout(lineHeight: 10, compact: 2, loose: 14)
    #expect(layout.gap(heights: [10, 10, 12]) == 2)
    #expect(layout.gap(heights: [10, 22]) == 14)
    #expect(layout.gap(heights: []) == 2)
  }

  @Test("a list marker is a bullet, a number, or a checkbox VoiceOver can name")
  func listMarkers() {
    #expect(CLIListMarker.glyph(ordered: false, task: .none) == "\u{2022}")
    #expect(CLIListMarker.glyph(ordered: true, task: .none).isEmpty)
    #expect(CLIListMarker.glyph(ordered: false, task: .checked) == "\u{2611}")
    #expect(CLIListMarker.glyph(ordered: true, task: .unchecked) == "\u{2610}")
    #expect(CLIListMarker.label(nil, task: .none).isEmpty)
    #expect(CLIListMarker.label(2, task: .none) == "2")
    #expect(CLIListMarker.label(nil, task: .checked) == "Done")
    #expect(CLIListMarker.label(3, task: .unchecked) == "3, Not done")
  }

  @Test("a block's line bound covers its text however it wraps in a narrow column")
  func lineBounds() {
    let wide = String(repeating: "w", count: MarkdownBlock.narrowestLine * 3)
    #expect(MarkdownBlock.paragraph(AttributedString("a\nb")).lineBound == 3)
    #expect(MarkdownBlock.heading(level: 1, text: AttributedString(wide)).lineBound == 5)
    #expect(MarkdownBlock.code(language: nil, code: "x\ny").lineBound == 2)
    #expect(MarkdownBlock.html("<p>").lineBound == 1)
    #expect(MarkdownBlock.math("x").lineBound == 1)
    #expect(MarkdownBlock.image(source: "a.png", alt: "b").lineBound == 2)
    #expect(MarkdownBlock.rule.lineBound == 1)
    #expect(MarkdownBlock.quote([.rule, .rule]).lineBound == 4)
    let item = MarkdownListItem(blocks: [.rule], task: .none)
    #expect(MarkdownBlock.list(ordered: false, start: 1, items: [item, item]).lineBound == 6)
    let table = MarkdownTable(header: ["h"], rows: [["a"], ["b"]], alignments: [.leading])
    #expect(MarkdownBlock.table(table).lineBound == 8)
  }

  @Test("a paragraph's source line breaks come back as line breaks, styles kept")
  func softBreaks() throws {
    guard
      case .paragraph(let text) = try #require(
        MarkdownParser.parse("one **two\nthree** four").first)
    else {
      Issue.record("expected a paragraph")
      return
    }
    #expect(String(text.characters) == "one two three four")
    let kept = text.keepingSoftBreaks
    #expect(String(kept.characters) == "one two\nthree four")
    #expect(kept.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    let plain = AttributedString("no breaks")
    #expect(plain.keepingSoftBreaks == plain)
  }
}
