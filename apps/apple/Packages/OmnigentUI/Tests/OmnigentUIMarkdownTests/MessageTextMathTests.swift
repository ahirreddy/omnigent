#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// Inline math typeset by KaTeX in a TextKit message, as ``MarkdownParagraphText`` sets it.
  @MainActor
  @Suite("Typeset inline math in a TextKit message", .serialized)
  struct MessageTextMathTests {
    private func height(_ renderer: MessageTextRenderer, _ markdown: String) -> CGFloat {
      let view = MessageMarkdown(text: markdown).environment(\.messageTextRenderer, renderer)
      let host = NSHostingView(
        rootView: view.frame(width: 600).fixedSize(horizontal: false, vertical: true))
      host.layoutSubtreeIfNeeded()
      return host.fittingSize.height
    }

    nonisolated static let math =
      "The ratio \\(\\frac{a}{b} + x_i^2\\) grows, and so does \\(\\sqrt{2}\\). "
      + String(repeating: "More words around it. ", count: 10)

    @Test("A paragraph with typeset inline math takes the height SwiftUI gives it")
    func mathHeight() async throws {
      for tex in MarkdownBlock.inlineMath(in: MarkdownParser.parse(Self.math)) {
        _ = try await RichBlockRenderer.shared.render(
          RichBlockRequest(
            kind: .math(display: false, size: MessageTextFixture.ramp.body), source: tex))
      }
      let swiftUI = height(.swiftUI, Self.math)
      let textKit = height(.textKit, Self.math)
      #expect(abs(swiftUI - textKit) < 1, "SwiftUI \(swiftUI), TextKit \(textKit)")
    }

    @Test("A paragraph's typeset math is an image on its baseline; headings and cells keep text")
    func inlineMath() throws {
      let markdown = "Area \\(x^2\\) here.\n\n## Heading \\(x^2\\)\n\n| A |\n| --- |\n| \\(x^2\\) |"
      let blocks = MarkdownParser.parse(markdown)
      #expect(MarkdownBlock.inlineMath(in: blocks) == ["x^2"], "a paragraph's math only")
      let context = try #require(
        unsafe CGContext(
          data: nil, width: 40, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      let image = try #require(context.makeImage())
      let typeset = RenderedRichBlock(
        image: image, scale: 2, size: CGSize(width: 20, height: 18), baseline: 14)
      var builder = MessageTextBuilder(palette: MessageTextPalette(MessageTextFixture.style))
      let unicode = builder.document(blocks).text
      #expect(unicode.string.contains("Area x² here."))
      builder = MessageTextBuilder(palette: MessageTextPalette(MessageTextFixture.style))
      builder.typesetMath = ["x^2": typeset]
      let text = builder.document(blocks).text
      let spot = MessageTextFixture.offset(of: "\u{FFFC}", in: text)
      #expect(spot == 5, "\(text.string)")
      let attachment = try #require(
        MessageTextFixture.value(.attachment, at: spot, in: text, as: NSTextAttachment.self))
      #expect(attachment.bounds == CGRect(x: 0, y: 0, width: 20, height: 18), "room above")
      let math = try #require(
        MessageTextFixture.value(.messageMath, at: spot, in: text, as: MessageMathMark.self))
      #expect(math.baseline == 14)
      #expect(math.size == CGSize(width: 20, height: 18))
      #expect(math.image.width == 40, "the image at its own pixels")
      let style = try #require(MessageTextFixture.paragraph(at: spot, in: text))
      #expect(style.maximumLineHeight == 0, "a line grows to fit its math")
      let whole = NSRange(location: 0, length: text.length)
      #expect(text.messageCopyText(in: whole).hasPrefix("Area x² here.\n"))
      let heading = try #require(
        MessageTextFixture.font(at: MessageTextFixture.offset(of: "x²", in: text), in: text))
      #expect(!heading.fontDescriptor.symbolicTraits.contains(.italic), "plain in a heading")
      #expect(heading.pointSize == MessageTextFixture.ramp.heading(2))
      let cell = MessageTextFixture.offset(of: "x²", in: text, after: "Heading x²")
      let cellFont = try #require(MessageTextFixture.font(at: cell, in: text))
      #expect(cellFont.pointSize == MessageTextFixture.ramp.body)
      #expect(!cellFont.fontDescriptor.symbolicTraits.contains(.italic), "plain in a cell")
    }

    @Test("Typeset inline math draws behind its clear attachment, its baseline on the line's")
    func mathLayer() async throws {
      let tex = "\\frac{a}{b}"
      let typeset = try await RichBlockRenderer.shared.render(
        RichBlockRequest(
          kind: .math(display: false, size: MessageTextFixture.ramp.body), source: tex))
      let screen = transcriptScreen(
        MessageMarkdown(text: "Ratio \\(\(tex)\\) here.").environment(
          \.messageTextRenderer, .textKit),
        width: 600, height: 300)
      defer { screen.close() }
      let content = try #require(MessageTextFixture.contentViews(in: screen).first)
      #expect(content.textView.string == "Ratio \u{FFFC} here.")
      let layers = try #require(content.subviews.compactMap { $0 as? MessageTextLayersView }.first)
      let rect = try #require(
        layers.shapes.compactMap { shape -> CGRect? in
          if case .image(_, let rect) = shape { return rect }
          return nil
        }.first)
      #expect(rect.size == typeset.size)
      let layout = try #require(content.textView.textLayoutManager)
      var baseline: CGFloat?
      var wordEnd: CGFloat = 0
      _ = layout.enumerateTextLayoutFragments(
        from: layout.documentRange.location, options: [.ensuresLayout]
      ) { fragment in
        if let line = fragment.textLineFragments.first {
          let bounds = line.typographicBounds
          baseline = fragment.layoutFragmentFrame.minY + bounds.minY + line.glyphOrigin.y
          wordEnd =
            fragment.layoutFragmentFrame.minX + bounds.minX + line.locationForCharacter(at: 6).x
        }
        return false
      }
      let lineBaseline = try #require(baseline)
      #expect(abs(rect.minY + typeset.baseline - lineBaseline) < 0.01, "\(rect) vs \(lineBaseline)")
      #expect(abs(rect.minX - wordEnd) < 0.01, "after the word before it")
    }
  }
#endif
