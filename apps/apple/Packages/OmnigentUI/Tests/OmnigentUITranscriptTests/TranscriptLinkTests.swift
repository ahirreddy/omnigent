#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  @Suite("Links in agent output open when clicked", .serialized)
  @MainActor
  struct TranscriptLinkTests {
    private static let address = "https://example.com/a/long/address/to/click"
    private let palette = CLIPalette(theme: .nord, dark: true, increasedContrast: false)

    private func plain(_ source: String, tintsMarkdown: Bool = true) -> AttributedString {
      SourceTinting.attributed(
        source, spans: tintsMarkdown ? SourceTinting.spans(in: source) : [], palette: palette,
        cursor: false)
    }

    private func linked(_ text: AttributedString) -> [String: String] {
      var found: [String: String] = [:]
      for run in text.runs {
        guard let link = run.link else { continue }
        found[link.absoluteString, default: ""] += String(text[run.range].characters)
      }
      return found
    }

    /// The addresses opened by a click on the first line of `view`.
    private func opened(byClicking view: some View, at point: CGPoint) throws -> [String] {
      var opened: [String] = []
      let screen = transcriptScreen(
        view.environment(
          \.openURL,
          OpenURLAction { url in
            opened.append(url.absoluteString)
            return .handled
          }))
      defer { screen.close() }
      screen.settle()
      try screen.click(point)
      screen.settle()
      return opened
    }

    @Test("Plain: a markdown link's whole source and a written-out address are links")
    func plainLinks() {
      let source = "Caf\u{00E9} [the **site**](https://a.test/x) and https://b.test/y, done.\n"
      let text = plain(source)
      #expect(String(text.characters) == source, "the source is unchanged")
      #expect(
        linked(text) == [
          "https://a.test/x": "[the **site**](https://a.test/x)",
          "https://b.test/y": "https://b.test/y",
        ])
      for run in text.runs where run.link != nil {
        #expect(run.underlineStyle == .single)
        #expect(run.foregroundColor != nil, "a link keeps a color of its own")
      }
    }

    @Test("Plain: a link that may not be opened is underlined text; raw output links addresses")
    func plainEdges() {
      let unsafe = plain("[run](javascript:alert(1)) or [file](file:///etc/passwd)")
      #expect(linked(unsafe).isEmpty)
      #expect(unsafe.runs.contains { $0.underlineStyle == .single })
      let output = "fetching https://c.test/z ... ok"
      let raw = plain(output, tintsMarkdown: false)
      #expect(linked(raw) == ["https://c.test/z": "https://c.test/z"])
      #expect(String(raw.characters) == output)
      #expect(linked(plain("no address here", tintsMarkdown: false)).isEmpty)
    }

    @Test("A click on a link opens it in the chat's rich text")
    func richClick() throws {
      let view = MarkdownView("[\(Self.address)](\(Self.address))")
      #expect(try opened(byClicking: view, at: CGPoint(x: 60, y: 12)) == [Self.address])
    }

    @Test(
      "A click on a link opens it in each CLI rendering",
      arguments: [OutputRendering.plain, .styled, .rich])
    func cliClick(rendering: OutputRendering) throws {
      let view = CLIOutputText(text: Self.address, isStreaming: false)
        .transcriptAppearance(TranscriptAppearance(style: .cli, outputRendering: rendering))
      #expect(
        try opened(byClicking: view, at: CGPoint(x: 60, y: rendering == .rich ? 12 : 9))
          == [Self.address])
    }

    @Test("A click on an address in a CLI user message opens it")
    func userTextClick() throws {
      let view = CLIUserText(text: Self.address)
      #expect(try opened(byClicking: view, at: CGPoint(x: 60, y: 9)) == [Self.address])
    }
  }
#endif
