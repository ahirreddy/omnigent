#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The CLI's TextKit text beside its SwiftUI views: the same block takes the same height, and
  /// its lines sit on the same baselines.
  @MainActor
  @Suite("CLI TextKit text beside SwiftUI's", .serialized)
  struct CLITextParityTests {
    static let width: CGFloat = 640

    nonisolated static let styled: [(name: String, markdown: String)] = [
      ("line", "Hello there, a single line."),
      (
        "wrapped",
        String(repeating: "A paragraph long enough to wrap over several lines. ", count: 6)
      ),
      ("softBreaks", "first line\nsecond line\nthird line"),
      ("headings", "# Title\n\n## Second\n\n### Third\n\n#### Minor\n\nBody."),
      ("list", "- one\n- two\n  - nested with *emphasis*\n- three"),
      ("looseList", "- " + String(repeating: "a wrapping list item ", count: 8) + "\n- short"),
      ("ordered", "1. first\n2. second\n10. tenth"),
      ("tasks", "- [x] reproduce\n- [x] fix\n- [ ] ship the release"),
      ("quote", "> Note: this is quoted.\n>\n> A second quoted paragraph."),
      ("code", "Before.\n\n```swift\n\(MessageTextParityTests.code(lines: 12))\n```\n\nAfter."),
      ("plainCode", "```\nplain block\n  indented\n```"),
      ("table", MessageTextParityTests.table(rows: 4)),
      ("rule", "Above.\n\n---\n\nBelow."),
      ("blocks", "<div>raw html</div>\n\n![a chart](./chart.png)\n\n$$x^2$$\n\nThe end"),
      (
        "inline",
        "Calls `process(batch:)` once; see [the note](https://example.com/n) and **bold**."
      ),
      ("answer", MessageTextParityTests.answer),
    ]

    nonisolated static let plain: [(name: String, text: String)] = [
      (
        "plain",
        "## Heading\n\nSome **bold** and `code`, a [link](https://example.com).\n\n- a\n- b"
      ),
      ("plainWrapped", String(repeating: "Plain output wraps like any other text. ", count: 8)),
    ]

    nonisolated static let prompts: [(name: String, text: String)] = [
      ("prompt", "Short?"),
      ("promptLines", "First line\nsecond line\n\nafter a blank"),
      ("promptQuote", "> It said this\n> and this\nMy reply to it"),
      ("promptLink", "See https://example.com/a for it"),
    ]

    /// The style at `scale`, the pixels per point SwiftUI rounds a text's height to: a hosting
    /// view with no window rounds to the point, one in a window to its pixel.
    private func style(scale: CGFloat = 1) -> CLITextStyle {
      CLITextStyle(
        points: CGFloat(TranscriptAppearance.defaultFontSize), scale: scale, palette: .fallback)
    }

    private var palette: MessageTextPalette {
      MessageTextPalette(
        MessageTextStyle(environment: EnvironmentValues(), code: MessageCodeFont()))
    }

    private func swiftUIHeight(_ view: some View) -> CGFloat {
      let host = NSHostingView(
        rootView: view.transcriptAppearance(TranscriptAppearance(style: .cli)).cliPalette()
          .frame(width: Self.width, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true))
      host.layoutSubtreeIfNeeded()
      return host.fittingSize.height
    }

    private func textKit(_ spec: CLITextSpec, scale: CGFloat = 1) -> CLITextDocument {
      CLITextDocument.make(spec, style: style(scale: scale), width: Self.width, palette: palette)
    }

    @Test("Styled output takes the height SwiftUI gives it", arguments: styled.map(\.name))
    func styledHeights(name: String) throws {
      let markdown = try #require(Self.styled.first { $0.name == name }?.markdown)
      let swiftUI = swiftUIHeight(CLIStyledMarkdown(text: markdown))
      let textKit = textKit(.styled(markdown)).height
      // The hosting view rounds its own height up to the point.
      expectClose(swiftUI, textKit.rounded(.up), name, within: 0.01)
    }

    @Test("Plain output takes the height SwiftUI gives it", arguments: plain.map(\.name))
    func plainHeights(name: String) throws {
      let text = try #require(Self.plain.first { $0.name == name }?.text)
      let swiftUI = swiftUIHeight(CLISourceText(text: text))
      let textKit = textKit(.plain(text)).height
      expectClose(swiftUI, textKit.rounded(.up), name, within: 0.01)
    }

    @Test("A prompt takes the height SwiftUI gives it", arguments: prompts.map(\.name))
    func promptHeights(name: String) throws {
      let text = try #require(Self.prompts.first { $0.name == name }?.text)
      let swiftUI = swiftUIHeight(CLIUserText(text: text))
      let textKit = textKit(.prompt(text)).height
      expectClose(swiftUI, textKit.rounded(.up), name, within: 0.01)
    }

    @Test("A turn's footer line takes the height SwiftUI gives it")
    func footerHeight() {
      let text = "Worked for 12s \u{2022} 9:47 PM"
      let swiftUI = swiftUIHeight(Text(verbatim: text).cliFont())
      expectClose(swiftUI, textKit(.footer(text)).height.rounded(.up), "footer", within: 0.01)
    }

    @Test("Every size's lines land on SwiftUI's pitch", arguments: [10.0, 13.0, 15.0, 22.0])
    func sizes(points: Double) {
      let markdown =
        "One paragraph that wraps " + String(repeating: "on and on ", count: 30)
        + "\n\n- a\n- b"
      let appearance = TranscriptAppearance(style: .cli, fontSize: points)
      let host = NSHostingView(
        rootView: CLIStyledMarkdown(text: markdown).transcriptAppearance(appearance).cliPalette()
          .frame(width: Self.width, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true))
      host.layoutSubtreeIfNeeded()
      var sized = style()
      sized.points = CGFloat(points)
      let document = CLITextDocument.make(
        .styled(markdown), style: sized, width: Self.width, palette: palette)
      expectClose(
        host.fittingSize.height, document.height.rounded(.up), "\(points) pt", within: 0.01)
    }

    @Test(
      "Lines sit on SwiftUI's baselines",
      arguments: ["headings", "list", "quote", "code", "table", "answer"])
    func baselines(name: String) throws {
      let markdown = try #require(Self.styled.first { $0.name == name }?.markdown)
      let (swiftUI, scale) = swiftUIBaselines(CLIStyledMarkdown(text: markdown))
      let textKit = try textKitBaselines(textKit(.styled(markdown), scale: scale))
      #expect(!textKit.isEmpty)
      for baseline in textKit {
        let nearest = swiftUI.min { abs($0 - baseline) < abs($1 - baseline) } ?? .infinity
        expectClose(nearest, baseline, "\(name) baseline", within: 0.01, context: "\(swiftUI)")
      }
    }

    @Test("A quote's markers and a table's rules sit where SwiftUI draws them")
    func decorations() {
      let quote = textKit(.styled("> one\n>\n> two"))
      let markers = quote.decorations.compactMap { decoration -> CGRect? in
        if case .markers(">", let rect, _) = decoration { return rect }
        return nil
      }
      #expect(markers.count == 1)
      #expect(markers.first?.minX == 0)
      #expect(markers.first.map { abs($0.height - quote.height) < 0.5 } == true)
      let table = textKit(.styled(MessageTextParityTests.table(rows: 2)))
      let rules = table.decorations.compactMap { decoration -> CGRect? in
        if case .fill(let rect, _, _) = decoration { return rect }
        return nil
      }
      // Five columns: a heavier rule under the header, one between the two rows.
      #expect(rules.count == 10)
      #expect(rules.prefix(5).allSatisfy { $0.height == 2 })
      #expect(rules.suffix(5).allSatisfy { $0.height == 1 })
    }

    @Test("A copy leaves list markers out, as the CLI's markers are views of their own")
    func copyLeavesMarkersOut() {
      let document = textKit(.styled("- one\n- two"))
      let text = document.text.text
      #expect(text.messageCopyText(in: NSRange(location: 0, length: text.length)) == "one\ntwo")
    }

    /// A mismatch, told on the failure's own line.
    struct Mismatch: Error, CustomStringConvertible {
      let description: String
    }

    private func expectClose(
      _ swiftUI: CGFloat, _ textKit: CGFloat, _ name: String, within: CGFloat = 0.5,
      context: String = ""
    ) {
      guard abs(swiftUI - textKit) >= within else { return }
      Issue.record(
        Mismatch(description: "\(name): SwiftUI \(swiftUI), TextKit \(textKit) \(context)"))
    }

    /// Each line's baseline as SwiftUI lays `view` out in a window, from the top, and the
    /// window's scale.
    private func swiftUIBaselines(_ view: some View) -> ([CGFloat], CGFloat) {
      let captured = CapturedBaselines()
      let screen = OffscreenWindow(
        AnyView(
          view.transcriptAppearance(TranscriptAppearance(style: .cli)).cliPalette()
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
              GeometryReader { proxy in
                Color.clear.onAppear {
                  for anchored in layouts {
                    let origin = proxy[anchored.origin]
                    captured.values += anchored.layout.map { origin.y + $0.origin.y }
                  }
                }
              }
            }
            .frame(width: Self.width, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)),
        width: Self.width, height: 2_000)
      defer { screen.close() }
      return (captured.values, screen.window.backingScaleFactor)
    }

    /// Each line's baseline as TextKit lays the document out, from the top.
    private func textKitBaselines(_ document: CLITextDocument) throws -> [CGFloat] {
      let storage = NSTextContentStorage()
      let manager = NSTextLayoutManager()
      storage.addTextLayoutManager(manager)
      let container = NSTextContainer(size: CGSize(width: Self.width, height: 1_000_000))
      container.lineFragmentPadding = 0
      manager.textContainer = container
      storage.textStorage?.setAttributedString(document.text.text)
      var baselines: [CGFloat] = []
      _ = manager.enumerateTextLayoutFragments(
        from: manager.documentRange.location, options: [.ensuresLayout]
      ) { fragment in
        baselines += fragment.textLineFragments.map { line in
          document.text.topInset + fragment.layoutFragmentFrame.minY
            + line.typographicBounds.minY + line.glyphOrigin.y
        }
        return true
      }
      return baselines
    }
  }
#endif
