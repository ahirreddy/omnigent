#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  @MainActor
  @Suite("A message's TextKit view", .serialized)
  struct MessageTextViewTests {
    private static let long = String(
      repeating: "Words that wrap across the column when it narrows. ", count: 12)

    @Test("Each width lays the text out once; a narrower one is taller")
    func layoutPerWidth() {
      let view = MessageTextContentView(document: MessageTextFixture.document(Self.long))
      let wide = view.fittingSize(for: 600, fillsWidth: true)
      #expect(view.layoutPasses == 1)
      #expect(view.fittingSize(for: 600, fillsWidth: true) == wide)
      #expect(view.layoutPasses == 1, "the same width reads the kept size")
      let narrow = view.fittingSize(for: 300, fillsWidth: true)
      #expect(view.layoutPasses == 2)
      #expect(narrow.height > wide.height)
      #expect(wide.width == 600)
      #expect(view.fittingSize(for: 600, fillsWidth: true) == wide)
      #expect(view.layoutPasses == 2, "a width measured before keeps its size")
      #expect(view.fittingSize(for: 0, fillsWidth: true).width == 0, "a minimum lays out nothing")
      #expect(view.layoutPasses == 2)
    }

    @Test("A bubble hugs short text, and keeps its layout at the narrower width")
    func hugging() {
      let view = MessageTextContentView(document: MessageTextFixture.document("Short"))
      let size = view.fittingSize(for: 500, fillsWidth: false)
      #expect(size.width > 10 && size.width < 100, "\(size)")
      view.frame = CGRect(origin: .zero, size: size)
      view.layoutSubtreeIfNeeded()
      #expect(view.layoutPasses == 1, "the measured layout fits the hugged width")
      let code = MessageTextContentView(document: MessageTextFixture.document("```\nx\n```"))
      #expect(code.fittingSize(for: 500, fillsWidth: false).width == 500, "code spans the bubble")
    }

    @Test("A row shown again gets its laid-out view back instead of a new one")
    func viewsComeBack() throws {
      let document = MessageTextFixture.document(Self.long)
      let first = MessageTextHostView()
      first.show(document, fillsWidth: true) { _ in }
      let made = MessageTextViews.shared.made
      let content = try #require(first.content)
      _ = first.fittingSize(for: 500)
      first.releaseContent()
      #expect(first.content == nil)
      let second = MessageTextHostView()
      second.show(document, fillsWidth: true) { _ in }
      #expect(second.content === content)
      #expect(MessageTextViews.shared.made == made)
      _ = second.fittingSize(for: 500)
      #expect(content.layoutPasses == 1, "nothing typeset again")
      let other = MessageTextHostView()
      other.show(document, fillsWidth: true) { _ in }
      #expect(other.content !== content, "a view shows in one row at a time")
      other.releaseContent()
      second.releaseContent()
    }

    @Test("Code blocks get a surface and a header with Copy; quotes a bar; tables their rules")
    func layersAndControls() throws {
      let markdown = """
        Intro.

        ```swift
        let a = 1
        let b = 2
        ```

        > Quoted line

        | A | B |
        | --- | --- |
        | 1 | 2 |
        | 3 | 4 |
        """
      let screen = transcriptScreen(
        MessageMarkdown(text: markdown).environment(\.messageTextRenderer, .textKit),
        width: 600, height: 700)
      defer { screen.close() }
      let content = try #require(MessageTextFixture.contentViews(in: screen).first)
      let layers = try #require(content.subviews.compactMap { $0 as? MessageTextLayersView }.first)
      let codeBlocks = layers.shapes.compactMap { shape -> CGRect? in
        if case .codeBlock(let rect) = shape { return rect }
        return nil
      }
      let ramp = MessageTextFixture.ramp
      let code = try #require(codeBlocks.first)
      let expected =
        MessageTextBuilder.codeHeaderHeight + 1 + 2 * MessageTextBuilder.codePadding
        + 2 * ramp.codeLineHeight
      #expect(abs(code.height - expected) < 1, "\(code.height) vs \(expected)")
      #expect(code.width == content.bounds.width)
      let fills = layers.shapes.compactMap { shape -> MessageTextShape.Fill? in
        if case .fill(_, let fill) = shape { return fill }
        return nil
      }
      #expect(fills.filter { $0 == .quoteBar }.count == 1)
      #expect(fills.filter { $0 == .border }.count == 1, "under the header row")
      #expect(fills.filter { $0 == .hover }.count == 1, "between the body rows")
      let header = try #require(content.subviews.compactMap { $0 as? MessageCodeHeaderView }.first)
      #expect(abs(header.frame.minY - code.minY) < 0.5)
      try screen.click(header.copyButton)
      #expect(copiedText() == "let a = 1\nlet b = 2")
      #expect(header.copyButton.title == "Copied")
      #expect(content.subviews.contains { $0 is MessageTableControlsView })
      #expect(content.frame.height >= code.maxY)
    }

    @Test("A link opens through the app on a click and shows the hand under the pointer")
    func links() throws {
      let address = "https://example.com/first"
      let hosted = LinkedTextScreen(
        MessageMarkdown(text: "Plain words, then [the site](\(address)), then more plain words.")
          .environment(\.messageTextRenderer, .textKit)
          .padding(40))
      defer { hosted.screen.close() }
      let content = try #require(MessageTextFixture.contentViews(in: hosted.screen).first)
      let link = try #require(content.linkRects.first)
      #expect(link.url.absoluteString == address)
      let text = content.textView
      let center = text.convert(
        CGPoint(x: link.rect.midX, y: link.rect.midY), to: hosted.screen.host)
      #expect(try hosted.openedByClicking(center) == [address])
      let beside = text.convert(
        CGPoint(x: link.rect.minX - 30, y: link.rect.midY), to: hosted.screen.host)
      #expect(try hosted.openedByClicking(beside).isEmpty)
      NSCursor.arrow.set()
      text.mouseMoved(with: try hosted.moved(to: beside))
      #expect(NSCursor.current != NSCursor.pointingHand)
      text.mouseMoved(with: try hosted.moved(to: center))
      #expect(NSCursor.current == NSCursor.pointingHand)
    }

    @Test("Only a settled message in the rich rendering draws with TextKit")
    func chooses() throws {
      let screen = transcriptScreen(
        VStack {
          MessageMarkdown(text: "Settled").environment(\.messageTextRenderer, .textKit)
          MessageMarkdown(text: "Streaming", isStreaming: true)
            .environment(\.messageTextRenderer, .textKit)
          MessageMarkdown(text: "Default")
        }, width: 400, height: 300)
      defer { screen.close() }
      let texts = MessageTextFixture.contentViews(in: screen).map(\.textView.string)
      #expect(texts == ["Settled"])
      #expect(
        MessageTextRenderer(defaults: Self.defaults(["omnigent:message-text": "textkit"]))
          == .textKit)
      #expect(
        MessageTextRenderer(defaults: Self.defaults(["omnigent:message-text": "other"])) == .swiftUI
      )
      #expect(MessageTextRenderer(defaults: Self.defaults([:])) == .swiftUI)
    }

    private static func defaults(_ values: [String: String]) -> UserDefaults {
      let suite = "message-text-\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: suite) ?? .standard
      defaults.removePersistentDomain(forName: suite)
      for (key, value) in values { defaults.set(value, forKey: key) }
      return defaults
    }
  }
#endif
