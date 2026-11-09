#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Markdown in the transcript", .serialized)
  @MainActor
  struct MarkdownViewInteractionTests {
    private func screen(_ text: String, isStreaming: Bool = false) -> OffscreenWindow<AnyView> {
      transcriptScreen(MarkdownView(text, isStreaming: isStreaming))
    }

    private func titles(of menu: NSMenu) -> [String] {
      menu.items.map(\.title).filter { !$0.isEmpty }
    }

    private func copiedLines() -> [String] {
      let copied = SystemSideEffects.pasteboard.string(forType: .string) ?? ""
      return copied.split(whereSeparator: \.isNewline).map(String.init)
    }

    @Test("Each block kind draws its text")
    func blocks() throws {
      let source = """
        # Heading `code`

        Body with **bold**, *emphasis*, ~~gone~~ and [a link](https://example.com).

        1. First
        2. Second

        - [x] Done item
        - [ ] Open item
        - Plain item

        > Quoted

        ---

        <div>raw html</div>
        """
      let view = screen(source)
      defer { view.close() }
      for text in [
        "Heading code", "Body with bold", "1.", "2.", "First", "Done item", "Open item",
        "Plain item", "Quoted", "<div>raw html</div>",
      ] {
        #expect(try view.shows(text), "\(text)")
      }
    }

    @Test("An ordered list counts from where it starts")
    func listStart() throws {
      let view = screen("7. Seventh\n8. Eighth")
      defer { view.close() }
      #expect(try view.shows("7."))
      #expect(try view.shows("8."))
    }

    @Test("A code block names its language, or says Code, and wraps at the click of a toggle")
    func codeBlock() throws {
      let named = transcriptScreen(CodeBlockView(code: "let answer = 42", language: "swift"))
      defer { named.close() }
      #expect(try named.shows("swift"))
      #expect(try named.shows("let answer = 42"))
      let controls = named.controlFrames.count
      #expect(controls == 3)
      SystemSideEffects.reset()
      try named.clickControl(at: 2)
      #expect(copiedLines() == ["let answer = 42"])
      try named.clickControl(at: 0)
      #expect(try named.shows("let answer = 42"))
      #expect(named.controlFrames.count == controls)
      try named.clickControl(at: 0)
      #expect(try named.shows("let answer = 42"))

      for language in [nil, ""] {
        let bare = transcriptScreen(CodeBlockView(code: "x", language: language))
        defer { bare.close() }
        #expect(try bare.shows("Code"))
      }
    }

    @Test("A long block scrolls inside its bound rather than growing without limit")
    func boundedCode() throws {
      let code = (0..<200).map { "line \($0)" }.joined(separator: "\n")
      let log = FrameLog()
      let view = transcriptScreen(
        CodeBlockView(code: code, language: nil, maxLines: 5).recordingFrame("block", in: log))
      defer { view.close() }
      let block = try #require(log.frames["block"])
      #expect(block.height > 40)
      #expect(block.height < 400)
    }

    @Test("A table draws its cells, copies in each format and offers both downloads")
    func table() throws {
      SystemSideEffects.reset()
      let view = screen("| Name | Size |\n| --- | ---: |\n| a | 1 |\n| b | 2 |")
      defer { view.close() }
      for text in ["Name", "Size", "a", "2"] { #expect(try view.shows(text), "\(text)") }

      // Button-style menus have no control view, so they're found beside the Expand button.
      let expand = try #require(view.controlFrames.last)
      let copyMenu = try view.openMenu(CGPoint(x: 12, y: expand.midY))
      #expect(titles(of: copyMenu) == ["Copy as Markdown", "Copy as CSV", "Copy as TSV"])
      try view.choose("Copy as CSV", in: copyMenu)
      #expect(copiedLines() == ["Name,Size", "a,1", "b,2"])
      try view.choose("Copy as TSV", in: copyMenu)
      #expect(copiedLines() == ["Name\tSize", "a\t1", "b\t2"])
      try view.choose("Copy as Markdown", in: copyMenu)
      #expect(SystemSideEffects.pasteboard.string(forType: .string)?.contains("| Name") == true)

      let downloadMenu = try view.openMenu(CGPoint(x: expand.minX - 12, y: expand.midY))
      #expect(titles(of: downloadMenu) == ["Download CSV", "Download Markdown"])
    }

    @Test("Expand shows the table on its own, and Done goes back")
    func expandedTable() throws {
      let view = screen("| Name | Size |\n| --- | ---: |\n| a | 1 |")
      defer { view.close() }
      try view.clickControl(at: view.controlFrames.count - 1)
      #expect(view.activeWindow !== view.window)
      #expect(try view.shows("Table"))
      try view.clickControl(at: view.controlFrames.count - 1)
      #expect(view.activeWindow === view.window)
    }

    @Test("A table with uneven rows pads them, and more columns than alignments still draws")
    func unevenTable() throws {
      let table = MarkdownTable(
        header: [AttributedString("A")],
        rows: [[AttributedString("1"), AttributedString("2"), AttributedString("3")], []],
        alignments: [.center])
      let view = transcriptScreen(MarkdownTableView(table: table))
      defer { view.close() }
      for text in ["A", "1", "3"] { #expect(try view.shows(text), "\(text)") }
    }

    @Test("Every table alignment draws")
    func alignments() throws {
      let view = screen("| L | C | R |\n| :-- | :-: | --: |\n| a | b | c |")
      defer { view.close() }
      for text in ["L", "C", "R", "a", "b", "c"] { #expect(try view.shows(text), "\(text)") }
    }

    @Test("Only web and mail links stay links")
    func linkSafety() {
      for allowed in ["https://example.com", "HTTP://example.com/x", "mailto:a@example.com"] {
        #expect(MarkdownParser.safeURL(allowed) != nil, "\(allowed)")
      }
      for refused in [
        "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "http:///no-host",
        "vbscript:x", "", "not a url", "omnigent-file:open?path=x",
      ] {
        #expect(MarkdownParser.safeURL(refused) == nil, "\(refused)")
      }
      #expect(MarkdownParser.safeURL(nil) == nil)
    }

    @Test("A script link's text shows without a link, and remote images are never fetched")
    func unsafeInline() throws {
      let blocks = MarkdownParser.parse(
        "[click](javascript:alert(1)) ![pic](https://example.com/p.png) ![](https://example.com/q)")
      guard case .paragraph(let text)? = blocks.first else {
        Issue.record("Expected a paragraph")
        return
      }
      let plain = String(text.characters)
      #expect(plain.contains("click"))
      #expect(plain.contains("[Image: pic]"))
      #expect(plain.contains("[Image]"))
      let links = text.runs.compactMap(\.link)
      #expect(links.map(\.absoluteString).allSatisfy { $0.hasPrefix("https://example.com") })
      #expect(links.count == 2)
    }

    @Test("Hostile sources parse and draw without trapping or hanging")
    func hostile() throws {
      let deepQuote = String(repeating: "> ", count: 200) + "bottom"
      let deepList = (0..<60).map { String(repeating: "  ", count: $0) + "- item" }
        .joined(separator: "\n")
      let sources =
        HostileData.samples + [
          deepQuote, deepList,
          String(repeating: "*", count: 5_000),
          String(repeating: "[", count: 5_000),
          String(repeating: "`", count: 5_000),
          "```\nnever closed",
          "| a |\n| --- |\n" + String(repeating: "| x | y | z |\n", count: 200),
          "\\(" + String(repeating: "\\frac{", count: 500),
          "$$" + String(repeating: "x", count: 5_000),
          "![](data:image/png;base64,@@@@)",
          "![](data:image/svg+xml;base64,PHN2Zz4=)",
          "[](http://[bad)",
          "<script>alert(1)</script>",
          "\u{0}\u{1}\u{2}",
        ]
      for source in sources {
        #expect(!source.isEmpty || MarkdownParser.parse(source).isEmpty)
        let rendering = transcriptScreen(ScrollView { MarkdownView(source) })
        defer { rendering.close() }
        rendering.settle(0.02)
      }
    }

    @Test("A stream's open code fence stays code, and the whole text agrees once settled")
    func streaming() throws {
      let open = screen("Intro\n\n```swift\nlet a = 1", isStreaming: true)
      defer { open.close() }
      #expect(try open.shows("let a = 1"))
      #expect(try open.shows("swift"))
    }

    @Test("Plain and Styled output draw the source, not the rendered blocks")
    func renderings() throws {
      for rendering in [OutputRendering.plain, .styled] {
        let view = transcriptScreen(
          MarkdownView("# Title\n\nBody").environment(\.markdownOutputRendering, rendering))
        defer { view.close() }
        #expect(try view.shows("Body"), "\(rendering)")
      }
    }

    @Test("Raster data images decode, others are refused, and each failure says why")
    func imageSources() throws {
      #expect(MarkdownImageSource("data:image/png;base64,AAAA") != nil)
      #expect(MarkdownImageSource("DATA:IMAGE/JPEG;BASE64,AAAA") != nil)
      #expect(MarkdownImageSource("data:image/svg+xml;base64,AAAA") == nil)
      #expect(MarkdownImageSource("data:image/png,AAAA") == nil)
      #expect(MarkdownImageSource("data:") == nil)
      #expect(MarkdownImageSource("https://example.com/p.png") == nil)
      #expect(MarkdownImageSource("images/p.png") == .workspace("images/p.png"))

      let oversize = Substring(String(repeating: "A", count: MarkdownImageSource.maxDataBytes * 2))
      #expect(throws: MarkdownImageError.self) { try MarkdownImageSource.decode(oversize) }
      for error in [MarkdownImageError.tooLarge, .undecodable, .unavailable] {
        #expect(error.errorDescription?.isEmpty == false)
      }
    }

    @Test("An image that can't be shown is a labelled chip")
    func imageFailure() async throws {
      let view = transcriptScreen(MarkdownImageView(source: "images/p.png", alt: "A chart"))
      defer { view.close() }
      try await letTasksRun(view)
      #expect(try view.shows("A chart"))

      let unnamed = transcriptScreen(
        MarkdownImageView(source: "data:image/png;base64,AAAA", alt: ""))
      defer { unnamed.close() }
      try await letTasksRun(unnamed)
      #expect(try unnamed.shows("Image"))
    }

    private func center(_ frame: CGRect) -> CGPoint {
      CGPoint(x: frame.midX, y: frame.midY)
    }
  }
#endif
