import CoreGraphics
import Foundation
import Testing

@testable import OmnigentBrowser

/// Annotate's picker script and the check of its answers, and the tools' value types.
@Suite("Design tools: picker and values")
struct DesignPickerTests {
  static func answer(
    element: String =
      ##"{"tag":"p","id":"#blurb","classes":".note","text":"Hello there","testId":"","ariaLabel":"Greeting","role":"note"}"##,
    rect: String = #"{"x":10,"y":20,"width":100,"height":40}"#,
    viewport: String = #"{"width":800,"height":600}"#, key: String = #""e1""#
  ) -> BrowserScriptValue {
    .string(#"{"element":\#(element),"rect":\#(rect),"viewport":\#(viewport),"key":\#(key)}"#)
  }

  @Test("the script asks for the point as a fraction of the page's viewport")
  func script() throws {
    let script = try #require(BrowserDesignPicker.script(at: CGPoint(x: 0.25, y: 1.5)))
    #expect(script.contains("at(0.25 * width, 1.0 * height)"))
    #expect(script.contains("getBoundingClientRect"))
    #expect(BrowserDesignPicker.script(at: CGPoint(x: Double.nan, y: 0)) == nil)
  }

  @Test("a picker's answer becomes a hit; JSON null is no element")
  func parsesHits() throws {
    let hit = try #require(try BrowserDesignPicker.hit(from: Self.answer()))
    #expect(hit.element.tag == "p" && hit.element.id == "#blurb" && hit.element.role == "note")
    #expect(hit.element.ariaLabel == "Greeting" && hit.key == "e1")
    #expect(hit.rect == CGRect(x: 10, y: 20, width: 100, height: 40))
    #expect(hit.viewport == CGSize(width: 800, height: 600))
    #expect(try BrowserDesignPicker.hit(from: .string("null")) == nil)
  }

  @Test("fields that aren't strings are dropped and long ones clamped")
  func checksFields() throws {
    let long = String(repeating: "a", count: 5000)
    let hit = try #require(
      try BrowserDesignPicker.hit(
        from: Self.answer(element: #"{"tag":7,"text":"\#(long)","role":null}"#)))
    #expect(hit.element.tag.isEmpty && hit.element.role.isEmpty)
    #expect(hit.element.text.count == BrowserDesignPicker.fieldLimit)
  }

  /// Answers that aren't the picker's.
  static let malformed: [BrowserScriptValue] = [
    .bool(true), .string("not json"), .string("[1]"),
    answer(rect: #"{"x":"10","y":20,"width":100,"height":40}"#),
    answer(viewport: #"{"width":0,"height":600}"#), answer(element: "3"),
  ]

  @Test("an answer that isn't the picker's is an error", arguments: malformed)
  func refusesMalformed(answer: BrowserScriptValue) {
    #expect(throws: BrowserError.self) { try BrowserDesignPicker.hit(from: answer) }
  }

  @Test("a hit maps onto a view of any size, and knows its own element")
  func hitGeometry() throws {
    let hit = try #require(try BrowserDesignPicker.hit(from: Self.answer()))
    #expect(
      hit.rect(in: CGSize(width: 1600, height: 1200))
        == CGRect(x: 20, y: 40, width: 200, height: 80))
    var moved = hit
    moved.rect.origin.y = 300
    #expect(moved.isSameElement(as: hit))
    moved.key = "e2"
    #expect(!moved.isSameElement(as: hit))
  }

  @Test("names and labels clip long text")
  func names() {
    let element = BrowserDesignElement(
      tag: "button", text: " Buy   now\n" + String(repeating: "x", count: 40))
    #expect(element.shortName == "button \"Buy now \(String(repeating: "x", count: 19))\u{2026}\"")
    #expect(BrowserDesignElement().shortName == "element")
    let annotate = BrowserDesignRequest(
      content: .element(BrowserDesignElement(tag: "h1"), request: "Bigger"), pageURL: nil,
      screenshotPNG: nil)
    #expect(annotate.label == "Annotate h1" && annotate.tool == .annotate)
    let draw = { (note: String, marks: Int) in
      BrowserDesignRequest(
        content: .drawing(note: note, marks: marks), pageURL: nil, screenshotPNG: nil
      )
      .label
    }
    #expect(draw(" Wider ", 2) == "Draw: Wider")
    #expect(draw("", 1) == "Draw: 1 mark" && draw("", 3) == "Draw: 3 marks")
  }

  @Test("a pen adds points, a rectangle or arrow keeps its start and end")
  func marks() {
    let start = CGPoint(x: 1, y: 1)
    let pen = BrowserDesignMark(kind: .pen, points: [start], color: .blue)
    #expect(!pen.isDrawn)
    let drawn = pen.extended(to: CGPoint(x: 2, y: 2)).extended(to: CGPoint(x: 3, y: 3))
    #expect(drawn.points.count == 3 && drawn.isDrawn)
    #expect(drawn.extended(to: CGPoint(x: 3, y: 3)) == drawn)
    let arrow = BrowserDesignMark(kind: .arrow, points: [start], color: .red)
      .extended(to: CGPoint(x: 5, y: 5)).extended(to: CGPoint(x: 9, y: 9))
    #expect(arrow.points == [start, CGPoint(x: 9, y: 9)])
    #expect(BrowserDesignMarkColor.blue.hex == 0x3B8FF5)
    #expect(BrowserDesignMarkColor.white.cgColor.components == [1, 1, 1, 1])
  }
}
