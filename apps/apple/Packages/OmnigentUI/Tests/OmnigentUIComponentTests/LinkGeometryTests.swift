import CoreGraphics
import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Where a text's links are")
struct LinkGeometryTests {
  private func text(_ pieces: [(String, String?)]) -> AttributedString {
    var text = AttributedString()
    for (words, address) in pieces {
      var piece = AttributedString(words)
      if let address { piece.link = URL(string: address) }
      text.append(piece)
    }
    return text
  }

  private func span(_ paragraph: Int, _ range: Range<Int>) -> LinkSpan {
    LinkSpan(paragraph: paragraph, range: range)
  }

  @Test("A text with no link has no spans, and an empty one none either")
  func noLink() {
    #expect(LinkGeometry.spans(in: text([("plain\nwords", nil)])).isEmpty)
    #expect(LinkGeometry.spans(in: AttributedString()).isEmpty)
  }

  @Test("A link's span counts UTF-16 units, as a layout numbers its glyphs")
  func spans() {
    let one = text([("see ", nil), ("the site", "https://a.test"), (" now", nil)])
    #expect(LinkGeometry.spans(in: one) == [span(0, 4..<12)])
    // "é" is one unit and the emoji two, so the link starts at 8.
    let accented = text([("Caf\u{00E9} \u{1F600} ", nil), ("link", "https://a.test")])
    #expect(LinkGeometry.spans(in: accented) == [span(0, 8..<12)])
    let two = text([("first", "https://a.test"), (" and ", nil), ("second", "https://b.test")])
    #expect(LinkGeometry.spans(in: two) == [span(0, 0..<5), span(0, 10..<16)])
  }

  @Test("A link styled in pieces, or two links with nothing between, are one span")
  func touchingLinks() throws {
    var styled = text([("a ", nil), ("bold", "https://a.test"), (" rest", "https://a.test")])
    styled[try #require(styled.range(of: "bold"))].inlinePresentationIntent = .stronglyEmphasized
    #expect(styled.runs.count == 3)
    #expect(LinkGeometry.spans(in: styled) == [span(0, 2..<11)])
    let touching = text([("first", "https://a.test"), ("second", "https://b.test")])
    #expect(LinkGeometry.spans(in: touching) == [span(0, 0..<11)])
  }

  @Test("Each line break starts a paragraph, counted from zero again")
  func paragraphs() {
    let later = text([("# Title\n\nfirst line\nsee ", nil), ("the site", "https://a.test")])
    #expect(LinkGeometry.spans(in: later) == [span(3, 4..<12)])
    let across = text([("a ", nil), ("one\ntwo\n", "https://a.test"), ("three", nil)])
    #expect(LinkGeometry.spans(in: across) == [span(0, 2..<5), span(1, 0..<3)])
    let twice = text([
      ("x\n", nil), ("one", "https://a.test"), ("\ny ", nil), ("two", "https://b.test"),
    ])
    #expect(LinkGeometry.spans(in: twice) == [span(1, 0..<3), span(2, 2..<5)])
    let returned = text([("done\rsee ", nil), ("the site", "https://a.test")])
    #expect(LinkGeometry.spans(in: returned) == [span(1, 4..<12)])
    let both = text([("one\r\ntwo\r", nil), ("\nthe site", "https://a.test")])
    #expect(LinkGeometry.spans(in: both) == [span(2, 0..<8)], "a return and a feed are one break")
    let separator = text([("ab\u{2029}c ", nil), ("the site", "https://a.test")])
    #expect(LinkGeometry.spans(in: separator) == [span(1, 2..<10)])
    // A line separator breaks the line and stays in its paragraph, counted.
    let separated = text([("ab\u{2028}", nil), ("cd", "https://a.test")])
    #expect(LinkGeometry.spans(in: separated) == [span(0, 3..<5)])
  }

  @Test("A text drawn with images counts each as one character")
  func imageRuns() {
    var math = AttributedString("x squared")
    math.inlinePresentationIntent = .code
    var composed = text([("area ", nil)])
    composed.append(math)
    composed.append(text([(" at ", nil), ("the site", "https://a.test")]))
    let isCode = { (run: AttributedString.Runs.Run) in run.inlinePresentationIntent == .code }
    #expect(LinkGeometry.spans(in: composed, imageRuns: isCode) == [span(0, 10..<18)])
    #expect(LinkGeometry.spans(in: composed, imageRuns: { _ in false }) == [span(0, 18..<26)])
    #expect(LinkGeometry.spans(in: text([("plain", nil)]), imageRuns: { _ in true }).isEmpty)
    var linked = AttributedString("pi")
    linked.link = URL(string: "https://a.test")
    linked.inlinePresentationIntent = .code
    var after = text([("one\nsee ", nil)])
    after.append(linked)
    #expect(LinkGeometry.spans(in: after, imageRuns: isCode) == [span(1, 4..<5)])
  }

  @Test("A laid-out line that does not go on from the one above starts a paragraph")
  func lineParagraphs() {
    let noLines: [ClosedRange<Int>?] = []
    #expect(LinkGeometry.paragraphs(ofLines: noLines).isEmpty)
    // Two wrapped lines, then a line break: the count starts again.
    #expect(LinkGeometry.paragraphs(ofLines: [0...18, 19...38, 0...3]) == [0, 0, 1])
    // An empty line is a paragraph of its own.
    #expect(LinkGeometry.paragraphs(ofLines: [0...1, nil, 0...1]) == [0, 1, 2])
    #expect(LinkGeometry.paragraphs(ofLines: [nil, nil, 0...8]) == [0, 1, 2])
    #expect(LinkGeometry.paragraphs(ofLines: [0...0, 0...0, 1...4]) == [0, 1, 1])
  }

  @Test("A run's glyphs in a link come back as ranges of their positions")
  func linkedPositions() {
    let links = [4..<8, 12..<14]
    #expect(LinkGeometry.linkedPositions(in: [], links: links).isEmpty)
    #expect(LinkGeometry.linkedPositions(in: [0, 1, 2, 3], links: links).isEmpty)
    #expect(LinkGeometry.linkedPositions(in: [8, 9, 10, 11], links: links).isEmpty)
    #expect(LinkGeometry.linkedPositions(in: [4, 5, 6, 7], links: links) == [0..<4])
    #expect(LinkGeometry.linkedPositions(in: [2, 3, 4, 5], links: links) == [2..<4])
    #expect(LinkGeometry.linkedPositions(in: [6, 7, 8, 9], links: links) == [0..<2])
    #expect(LinkGeometry.linkedPositions(in: Array(0..<16), links: links) == [4..<8, 12..<14])
    // A cluster of several units is one glyph at its first unit.
    #expect(LinkGeometry.linkedPositions(in: [2, 4, 6, 8], links: links) == [1..<3])
  }

  @Test("A right-to-left run's glyphs count down")
  func rightToLeft() {
    #expect(LinkGeometry.linkedPositions(in: [9, 8, 7, 6, 5, 4, 3], links: [4..<8]) == [2..<6])
  }

  @Test("Link rectangles that touch on a line become one, left to right")
  func joined() {
    let left = CGRect(x: 10, y: 0, width: 30, height: 16)
    let touching = CGRect(x: 40, y: 1, width: 20, height: 14)
    let apart = CGRect(x: 80, y: 0, width: 10, height: 16)
    #expect(LinkGeometry.joined([]).isEmpty)
    #expect(LinkGeometry.joined([apart, touching, left]) == [left.union(touching), apart])
    #expect(LinkGeometry.joined([left, apart]) == [left, apart])
  }
}
