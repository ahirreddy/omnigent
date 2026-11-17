#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// A TextKit message's code block header, as ``CodeBlockView``'s: its label, Wrap, Download
  /// and Copy.
  @MainActor
  @Suite("A TextKit message's code block controls", .serialized)
  struct MessageTextCodeBlockTests {
    @Test("A code block's header puts its label, Wrap, Download and Copy where SwiftUI's does")
    func codeHeader() throws {
      let markdown = "```swift\nlet a = 1\n```"
      let capturedLines = CapturedPoints()
      let swiftUI = Self.swiftUIScreen(markdown, capturing: capturedLines)
      defer { swiftUI.close() }
      // The label is the header's first line; its controls are the last two of three.
      let label = try #require(
        capturedLines.values.min { $0.y < $1.y || ($0.y == $1.y && $0.x < $1.x) })
      let swiftUIControls = swiftUI.controlFrames
      let textKit = OffscreenWindow(
        AnyView(
          MessageMarkdown(text: markdown).environment(\.messageTextRenderer, .textKit)
            .frame(width: 600, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)),
        width: 600, height: 300)
      defer { textKit.close() }
      let header = try #require(textKit.allViews.compactMap { $0 as? MessageCodeHeaderView }.first)
      let content = try #require(MessageTextFixture.contentViews(in: textKit).first)
      let baseline = try Self.labelBaseline(in: content, to: textKit.host)
      #expect(
        abs(baseline.x - label.x) < 0.5 && abs(baseline.y - label.y) < 0.5,
        "\(baseline) vs \(label)")
      let buttons = [header.downloadButton, header.copyButton].map {
        $0.convert($0.bounds, to: textKit.host)
      }
      for (button, expected) in zip(buttons, swiftUIControls.suffix(2)) {
        #expect(
          abs(button.minX - expected.minX) < 2 && abs(button.maxX - expected.maxX) < 0.5,
          "\(button) vs \(expected)")
        #expect(abs(button.minY - expected.minY) < 0.5 && button.height == expected.height)
      }
      let wrap = header.wrapButton.convert(header.wrapButton.bounds, to: textKit.host)
      #expect(wrap.width == Theme.Control.target)
      #expect(abs(wrap.maxX + Theme.Spacing.small - buttons[0].minX) < 0.5)
      #expect(header.copyButton.title == "Copy code")
    }

    /// SwiftUI's rendering of `markdown`, each line's baseline origin captured.
    private static func swiftUIScreen(_ markdown: String, capturing captured: CapturedPoints)
      -> OffscreenWindow<AnyView>
    {
      OffscreenWindow(
        AnyView(
          MarkdownView(markdown)
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
              GeometryReader { proxy in
                Color.clear.onAppear {
                  for anchored in layouts {
                    let origin = proxy[anchored.origin]
                    for line in anchored.layout {
                      captured.values.append(
                        CGPoint(x: origin.x + line.origin.x, y: origin.y + line.origin.y))
                    }
                  }
                }
              }
            }
            .frame(width: 600, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)),
        width: 600, height: 300)
    }

    /// Where the text draws the code block's label: its first glyph on its baseline.
    private static func labelBaseline(in content: MessageTextContentView, to host: NSView) throws
      -> CGPoint
    {
      let layout = try #require(content.textView.textLayoutManager)
      var found: CGPoint?
      _ = layout.enumerateTextLayoutFragments(
        from: layout.documentRange.location, options: [.ensuresLayout]
      ) { fragment in
        guard let line = fragment.textLineFragments.first else { return true }
        let frame = fragment.layoutFragmentFrame
        found = CGPoint(
          x: frame.minX + line.typographicBounds.minX + line.locationForCharacter(at: 0).x,
          y: frame.minY + line.typographicBounds.minY + line.glyphOrigin.y)
        return false
      }
      return content.textView.convert(try #require(found), to: host)
    }

    private static let longCode =
      "```swift\nlet a = \"\(String(repeating: "longIdentifier ", count: 30))\"\nlet b = 2\n```"

    /// A long code block in a screen, its text view and its header.
    private struct CodeScreen {
      let screen: OffscreenWindow<AnyView>
      let content: MessageTextContentView
      let header: MessageCodeHeaderView
    }

    private func codeScreen(width: CGFloat = 500) throws -> CodeScreen {
      let screen = transcriptScreen(
        MessageMarkdown(text: Self.longCode).environment(\.messageTextRenderer, .textKit)
          .frame(maxHeight: .infinity, alignment: .top),
        width: width, height: 600)
      let content = try #require(MessageTextFixture.contentViews(in: screen).first)
      let header = try #require(content.subviews.compactMap { $0 as? MessageCodeHeaderView }.first)
      return CodeScreen(screen: screen, content: content, header: header)
    }

    @Test(
      "Wrap off scrolls a code block's long lines sideways over its hidden text; on wraps again")
    func codeWrap() throws {
      let hosted = try codeScreen()
      let (screen, content, header) = (hosted.screen, hosted.content, hosted.header)
      defer { screen.close() }
      let wrapped = content.frame.height
      #expect(header.wrapsLines)
      #expect(header.wrapButton.toolTip == "Scroll long lines")
      #expect(content.overflows.isEmpty)
      try screen.click(header.wrapButton)
      screen.settle()
      #expect(!header.wrapsLines)
      #expect(header.wrapButton.toolTip == "Wrap long lines")
      let ramp = MessageTextFixture.ramp
      let unwrapped =
        MessageTextBuilder.codeHeaderHeight + 1 + 2 * MessageTextBuilder.codePadding
        + 2 * ramp.codeLineHeight
      #expect(abs(content.frame.height - unwrapped) < 1, "\(content.frame.height) from \(wrapped)")
      let overflow = try #require(content.overflows.values.first)
      #expect(overflow.contentWidth > overflow.bounds.width, "the long line scrolls")
      #expect(overflow.textView.string.contains("let b = 2"))
      let shown = try #require(content.textView.textContentStorage?.attributedString)
      let color = MessageTextFixture.value(
        .foregroundColor, at: "let b", in: shown, as: NSColor.self)
      #expect(color == .clear, "the copy over it draws the code")
      #expect(overflow.hasHorizontalScroller && !overflow.hasVerticalScroller)
      let transcript = ScrollSpy()
      // AppKit declares `nextResponder` unowned(unsafe); the test keeps both alive.
      let next = unsafe overflow.nextResponder
      unsafe overflow.nextResponder = transcript
      defer { unsafe overflow.nextResponder = next }
      overflow.scrollWheel(with: try Self.scroll(across: 0, down: -40))
      #expect(transcript.scrolls == 1, "a vertical scroll goes on to the transcript")
      overflow.scrollWheel(with: try Self.scroll(across: -60, down: 0))
      #expect(transcript.scrolls == 1, "a sideways one stays with the code")
      try screen.click(header.wrapButton)
      screen.settle()
      #expect(header.wrapsLines)
      #expect(content.overflows.isEmpty)
      #expect(abs(content.frame.height - wrapped) < 1)
    }

    /// Counts the scrolls that reach it.
    private final class ScrollSpy: NSResponder {
      var scrolls = 0
      override func scrollWheel(with event: NSEvent) { scrolls += 1 }
    }

    /// A trackpad scroll by `across` and `down` points.
    private static func scroll(across: Int32, down: Int32) throws -> NSEvent {
      let event = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: down,
        wheel2: across, wheel3: 0)
      return try #require(event.flatMap(NSEvent.init(cgEvent:)))
    }

    @Test("A code block's Download saves the code, and Copy lights up under the pointer")
    func codeDownloadAndHover() async throws {
      SystemSideEffects.reset()
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("message-text-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let url = folder.appendingPathComponent("snippet.swift")
      SystemSideEffects.answer(panel: .OK, panelURL: url)
      let hosted = try codeScreen()
      let (screen, header) = (hosted.screen, hosted.header)
      defer { screen.close() }
      #expect(header.downloadButton.accessibilityIdentifier() == "markdown.code.download")
      try screen.click(header.downloadButton)
      let saved = await screen.waitUntil { FileManager.default.fileExists(atPath: url.path) }
      #expect(saved, "panels shown: \(SystemSideEffects.record.panelCount)")
      let code = try String(contentsOf: url, encoding: .utf8)
      #expect(code.hasPrefix("let a = \"longIdentifier") && code.hasSuffix("let b = 2"))
      let point = try #require(
        NSEvent.mouseEvent(
          with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: screen.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0,
          pressure: 0))
      #expect(!header.copyButton.isHovered)
      header.copyButton.mouseEntered(with: point)
      #expect(header.copyButton.isHovered)
      header.copyButton.mouseExited(with: point)
      #expect(!header.copyButton.isHovered)
    }
  }

  @MainActor
  final class CapturedPoints {
    var values: [CGPoint] = []
  }
#endif
