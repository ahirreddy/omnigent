import Foundation
import Testing

@testable import OmnigentUIComponents

#if os(macOS)
  import AppKit
  import OmnigentViewTesting

  @testable import OmnigentUITestSupport
#endif

/// Design-tool messages read back as the web's chat reads them (`parseDesignRequest`).
@Suite("Design request")
struct DesignRequestTests {
  /// A picked element's message, as the web's design mode and Annotate build it.
  private static func element(_ fields: [String], asking request: String) -> String {
    let block = ["[Design Mode \u{2014} modify this element in the browser preview]"] + fields
    return "\(request)\n\n---\n\(block.joined(separator: "\n"))\n---"
  }

  private static func drawing(page: String, note: String) -> String {
    "\(note)\n\n---\n[Design Mode \u{2014} marked-up screenshot of the browser preview]\n"
      + "Page: \(page)\nThe attached screenshot shows the page with my marks drawn on it.\n---"
  }

  @Test("reads back a picked element's request and a drawing's note and page")
  func readsBack() throws {
    let text = Self.element(
      ["Element: <p>", "CSS selector: #blurb", "Text: \"Your orders ship in two days.\""],
      asking: "Make it red")
    var expected = DesignRequest(kind: .element, request: "Make it red")
    expected.element = "p#blurb"
    expected.elementText = "Your orders ship in two days."
    #expect(DesignRequest.parse(text) == expected)
    let drawing = try #require(
      DesignRequest.parse(Self.drawing(page: "http://localhost:5173", note: "Bigger heading")))
    #expect(drawing.kind == .drawing && drawing.request == "Bigger heading")
    #expect(drawing.subject == "Drawing on localhost:5173")
  }

  @Test("shows only the host of a page an older message saved with its path")
  func pageHost() {
    let saved = { (page: String) in DesignRequest.parse(Self.drawing(page: page, note: "Note")) }
    #expect(saved("https://example.test/invite/swordfish?code=\u{2026}")?.page == "example.test")
    #expect(saved("file: page")?.page == nil)
    #expect(saved("(unknown page)")?.page == nil)
  }

  @Test("reads only the block appended last; needs the generated header and its fields")
  func lastBlockOnly() {
    let quoted = Self.element(
      ["Element: <h1>", "CSS selector: h1", "Text: \"Old\""], asking: "Earlier")
    let text = Self.element(
      ["Element: <p>", "CSS selector: #blurb", "Text: \"New\""], asking: "\(quoted)\n\nNow this")
    let parsed = DesignRequest.parse(text)
    #expect(parsed?.element == "p#blurb" && parsed?.elementText == "New")
    #expect(parsed?.request == "\(quoted)\n\nNow this")
    for prose in [
      "Hi\n\n---\n[Design Mode \u{2014} modify this element?]\nSome prose\n---",
      Self.element(["Prose"], asking: "Hi"),
      "Hi\n\n---\n[Design Mode \u{2014} marked-up screenshot of the browser preview]\nProse\n---",
      "Please fix the build", "Intro\n\n---\nnot a design block\n---",
    ] {
      #expect(DesignRequest.parse(prose) == nil, "\(prose)")
    }
  }

  @Test("names a component, a label and role, a page, and a missing screenshot")
  func subjects() throws {
    let component = try #require(
      DesignRequest.parse(
        Self.element(
          ["Element: <CheckoutButton>", "CSS selector: button.primary"], asking: "Red")))
    #expect(component.element == "button.primary" && component.component == "CheckoutButton")
    #expect(component.subject == "<CheckoutButton> button.primary")
    let labelled = try #require(
      DesignRequest.parse(
        Self.element(
          [
            "Element: <button>", "CSS selector: #close", "Aria-label: \"Close dialog\"",
            "Role: button",
          ],
          asking: "Bigger")))
    #expect(labelled.subject == "button#close aria-label \"Close dialog\" role button")
    let paged = try #require(
      DesignRequest.parse(
        Self.element(
          [
            "Element: <p>", "CSS selector: p", "Page: https://example.test/orders",
            "Screenshot: none attached (it couldn't be taken)",
          ], asking: "Red")))
    #expect(paged.subject == "p on example.test" && paged.noScreenshot)
    let unknown = DesignRequest.parse(
      Self.element(["Element: <element>", "CSS selector: [data-testid=\"x\"]"], asking: "Red"))
    #expect(unknown?.element == "[data-testid=\"x\"]" && unknown?.component == nil)
  }

  @Test("parses many repeated headers quickly")
  func repeatedHeaders() {
    let header = "\n\n---\n[Design Mode \u{2014} modify this element in the browser preview]\n"
    let text = String(repeating: header, count: 20_000)
    #expect(DesignRequest.parse(text) == nil)
    #expect(DesignRequest.parse("\(text)x\n---") == nil)
  }

  @Test("a collapsed prompt bounds the request and element text together, on whole characters")
  func clipping() {
    var request = DesignRequest(kind: .element, request: String(repeating: "a", count: 8))
    request.element = "p"
    request.elementText = String(repeating: "b", count: 8)
    #expect(request.clipped(to: 10).request == request.request)
    #expect(request.clipped(to: 10).elementText == "b\u{2026}")
    request.request = String(repeating: "\u{1F600}", count: 4)
    #expect(request.clipped(to: 10).elementText == "bbbbb\u{2026}")
    var labelled = DesignRequest(kind: .element, request: String(repeating: "a", count: 10))
    labelled.element = "button"
    labelled.elementText = "Buy now"
    labelled.ariaLabel = "Buy now"
    #expect(labelled.clipped(to: 10).subject == "button \"\u{2026}\"")
    var short = labelled
    short.request = "a"
    #expect(short.clipped(to: 10) == short)
  }

  @Test("the CLI prompt shows the words, then the subject dim")
  func cliRuns() {
    let text = Self.drawing(page: "http://localhost:5173/a", note: "Bigger heading")
    #expect(
      UserPrompt.runs(text) == [
        UserPrompt.Run(text: "Bigger heading", isQuote: false),
        UserPrompt.Run(text: "\u{21B3} Drawing on localhost:5173", isQuote: false, isNote: true),
      ])
  }
}

#if os(macOS)
  /// The table transcript's text cell shows a design-tool message as the SwiftUI row does.
  @Suite("Design request in a text cell", .serialized)
  @MainActor
  struct DesignRequestTextCellTests {
    init() {
      SystemSideEffects.reset()
    }

    @Test("A design-tool message is its words over its subject, as tall as SwiftUI's row")
    func matchesSwiftUI() throws {
      let text =
        "Make it red\n\n---\n[Design Mode \u{2014} modify this element in the browser preview]\n"
        + "Element: <p>\nCSS selector: #blurb\n---"
      let cell = try shownMatchingSwiftUI(
        textCellRow(Row(id: "u-design", role: .user, text: text)), textCellEnvironment())
      #expect(cell.message?.markdown == "Make it red", "the block leaves the text")
      let subject = try #require(cell.accessoryViews.first)
      #expect(subject.accessory == .designSubject(try #require(DesignRequest.parse(text))))
      let words = try #require(cell.runs.first?.view)
      #expect(words.frame.maxY + Theme.Spacing.small <= subject.frame.minY + 0.5)
    }
  }
#endif
