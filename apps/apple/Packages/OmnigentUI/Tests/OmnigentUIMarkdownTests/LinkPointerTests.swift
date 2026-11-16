#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  @Suite("Each text finds where its links were drawn", .serialized)
  @MainActor
  struct LinkPointerTests {
    private static let first = "https://a.test/first"
    private static let second = "https://b.test/second"

    private func cli(_ text: String, _ rendering: OutputRendering) -> some View {
      CLIOutputText(text: text, isStreaming: false)
        .transcriptAppearance(TranscriptAppearance(style: .cli, outputRendering: rendering))
    }

    @Test("A text with no link gets no pointer areas, in any rendering")
    func noLink() {
      let views: [AnyView] =
        [AnyView(MarkdownView("# Plain\n\nwords and `code`\n\n| a | b |\n|---|---|\n| c | d |"))]
        + [OutputRendering.plain, .styled, .rich].map { AnyView(cli("# Plain\n\nwords", $0)) }
        + [AnyView(CLIUserText(text: "plain words")), AnyView(InlineMarkdownText("**plain**"))]
      for view in views {
        let hosted = LinkedTextScreen(view)
        defer { hosted.screen.close() }
        #expect(hosted.areas.isEmpty)
      }
    }

    @Test("One link has one rectangle, and a click in it opens the link")
    func oneLink() throws {
      let hosted = LinkedTextScreen(
        MarkdownView("Caf\u{00E9} \u{1F600} see [the site](\(Self.first)) now"))
      defer { hosted.screen.close() }
      let rects = hosted.linkRects
      try #require(rects.count == 1)
      #expect(rects[0].width > 20 && rects[0].height > 8)
      try hosted.expectEdges(of: rects[0], open: Self.first)
    }

    @Test("Two links have a rectangle each")
    func twoLinks() throws {
      let hosted = LinkedTextScreen(
        MarkdownView("[one](\(Self.first)) and then [two](\(Self.second))."))
      defer { hosted.screen.close() }
      let rects = hosted.linkRects
      try #require(rects.count == 2)
      #expect(rects[0].maxX < rects[1].minX)
      #expect(try hosted.openedByClicking(rects[0].center) == [Self.first])
      #expect(try hosted.openedByClicking(rects[1].center) == [Self.second])
    }

    @Test("A link that wraps has a rectangle on each of its lines")
    func wrappingLink() throws {
      let label = "a link with enough words in it to run on to a second line"
      let hosted = LinkedTextScreen(
        MarkdownView("Read [\(label)](\(Self.first)) first."), width: 260)
      defer { hosted.screen.close() }
      let rects = hosted.linkRects
      try #require(rects.count >= 2)
      for (above, below) in zip(rects, rects.dropFirst()) {
        #expect(below.minY >= above.maxY - 1, "each piece is on the line under the last")
      }
      #expect(rects[1].minX < rects[0].minX, "the second piece starts at its line's start")
      for rect in rects {
        #expect(try hosted.openedByClicking(rect.center) == [Self.first])
      }
    }

    @Test("A heading, a list item, a quote and a table cell each find their link")
    func richBlocks() throws {
      let source = """
        # Head [h](https://a.test/h)

        - item [i](https://a.test/i)

        > quote [q](https://a.test/q)

        | name |
        |------|
        | cell [c](https://a.test/c) |
        """
      let hosted = LinkedTextScreen(MarkdownView(source))
      defer { hosted.screen.close() }
      let rects = hosted.linkRects
      try #require(rects.count == 4)
      for (rect, name) in zip(rects, ["h", "i", "q", "c"]) {
        #expect(try hosted.openedByClicking(rect.center) == ["https://a.test/\(name)"])
      }
    }

    @Test(
      "Each CLI rendering finds a link on a later line of its text",
      arguments: [OutputRendering.plain, .styled, .rich])
    func cliRenderings(rendering: OutputRendering) throws {
      let hosted = LinkedTextScreen(cli("# Title\n\nfirst line\nsee \(Self.first) now", rendering))
      defer { hosted.screen.close() }
      let rects = hosted.linkRects
      try #require(rects.count == 1)
      try hosted.expectEdges(of: rects[0], open: Self.first)
    }

    @Test(
      "Tool output finds a link after a carriage return, a return and a feed, or a separator",
      arguments: [
        "done\rsee https://a.test/first now", "one\r\ntwo\r\nsee https://a.test/first now",
        "one\u{2029}see https://a.test/first now", "one\u{2028}see https://a.test/first now",
      ])
    func carriageReturns(output: String) throws {
      let hosted = LinkedTextScreen(CLISourceText(text: output, tintsMarkdown: false))
      defer { hosted.screen.close() }
      let rects = hosted.linkRects
      try #require(rects.count == 1)
      try hosted.expectEdges(of: rects[0], open: Self.first)
    }

    @Test("Styled CLI output finds a link's text and the address after it, in prose and tables")
    func styledPieces() throws {
      let source = """
        ## Go [here](\(Self.first))

        | where |
        |-------|
        | \(Self.second) |
        """
      let hosted = LinkedTextScreen(cli(source, .styled))
      defer { hosted.screen.close() }
      let rects = hosted.linkRects
      try #require(rects.count == 3)
      #expect(try hosted.openedByClicking(rects[0].center) == [Self.first])
      #expect(try hosted.openedByClicking(rects[1].center) == [Self.first])
      #expect(try hosted.openedByClicking(rects[2].center) == [Self.second])
    }

    @Test("A CLI user message and a decision's text find their links")
    func otherTexts() throws {
      let user = LinkedTextScreen(
        CLIUserText(text: "> quoted \(Self.first)\n\nmine\nand \(Self.second)"))
      defer { user.screen.close() }
      let rects = user.linkRects
      try #require(rects.count == 2)
      #expect(try user.openedByClicking(rects[0].center) == [Self.first])
      #expect(try user.openedByClicking(rects[1].center) == [Self.second])

      let decision = LinkedTextScreen(
        InlineMarkdownText("Allow **fetch** of [the page](\(Self.first))?"))
      defer { decision.screen.close() }
      let asked = decision.linkRects
      try #require(asked.count == 1)
      #expect(try decision.openedByClicking(asked[0].center) == [Self.first])
    }

    @Test("A paragraph with typeset math counts the math's image as one character")
    func typesetMath() throws {
      let parsed = MarkdownParser.parse("Area \\(\\pi r^2\\) at \(Self.first) ok").first
      guard case .paragraph(let paragraph)? = parsed else {
        Issue.record("expected a paragraph")
        return
      }
      let renderer = ImageRenderer(content: Color.gray.frame(width: 40, height: 16))
      renderer.scale = 1
      let image = try #require(renderer.cgImage)
      let typeset = { (_: RichBlockRequest) -> RenderedRichBlock? in
        RenderedRichBlock(image: image, scale: 1, size: CGSize(width: 40, height: 16), baseline: 12)
      }
      let links = MarkdownParagraphText.linkSpans(in: paragraph, size: 14, typeset: typeset)
      #expect(links == [LinkSpan(paragraph: 0, range: 10..<10 + Self.first.utf16.count)])
      #expect(
        MarkdownParagraphText.linkSpans(in: paragraph, size: 14, typeset: { _ in nil })
          == LinkGeometry.spans(in: paragraph), "math still in Unicode keeps its characters")
      let hosted = LinkedTextScreen(
        MarkdownParagraphText.compose(paragraph, size: 14, typeset: typeset)
          .linkPointer(links).textSelection(.enabled))
      defer { hosted.screen.close() }
      let rects = hosted.linkRects
      try #require(rects.count == 1)
      try hosted.expectEdges(of: rects[0], open: Self.first)
    }
  }
#endif
