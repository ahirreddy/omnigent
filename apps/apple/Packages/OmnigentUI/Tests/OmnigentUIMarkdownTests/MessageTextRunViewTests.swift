#if os(iOS)
  import OmnigentViewTesting
  import Testing
  import UIKit

  @testable import OmnigentUIComponents

  /// The iPhone and iPad text cells' surface: a run drawn ahead shows as its bitmap at the
  /// raster's size, a tap opens its links, and a long press lays selectable TextKit 2 text over
  /// the drawing until a tap ends it.
  @MainActor
  @Suite("Message text run view")
  struct MessageTextRunViewTests {
    private static let width: CGFloat = 280

    private var style: MessageTextRasterStyle {
      MessageTextRasterStyle(
        codeSurface: UIColor.secondarySystemBackground.cgColor,
        codeHeader: UIColor.tertiarySystemBackground.cgColor,
        separator: UIColor.separator.cgColor, border: UIColor.separator.cgColor,
        quoteBar: UIColor.systemGray.cgColor, link: UIColor.link.cgColor, codeRadius: 6)
    }

    /// A paragraph with a link, as the document builder makes one.
    private func run() throws -> MessageTextRun {
      let url = try #require(URL(string: "https://example.com/docs"))
      let text = NSMutableAttributedString(
        string: "Read the docs before you start, then come back to this paragraph.",
        attributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.label])
      let words = try #require(text.string.range(of: "docs"))
      let range = NSRange(words, in: text.string)
      text.addAttribute(.link, value: url, range: range)
      return MessageTextRun(text: text, topInset: 6, links: [(range: range, url: url)])
    }

    private func shown(_ run: MessageTextRun) throws -> (MessageTextRunView, InProcessWindow) {
      let raster = MessageTextRaster.make(run, width: Self.width, scale: 3, style: style)
      let view = MessageTextRunView(run: run, raster: raster)
      let window = try InProcessWindow(
        view: view, width: Self.width, height: raster.size.height)
      return (view, window)
    }

    @Test("A run shows its drawing at the raster's size, and a tap on its link opens it")
    func drawnAndLinked() throws {
      let (view, window) = try shown(try run())
      defer { window.close() }
      let raster = view.raster
      #expect(raster.size.height > 40)
      #expect(view.intrinsicContentSize == CGSize(width: Self.width, height: raster.size.height))
      #expect(view.image.showsDrawing)
      #expect(view.image.frame.minY == raster.topInset)
      var opened: [URL] = []
      view.openURL = { opened.append($0) }
      let area = try #require(raster.links.first)
      view.tap(at: CGPoint(x: area.rect.midX, y: area.rect.midY + raster.topInset))
      #expect(opened == [area.url])
      view.tap(at: CGPoint(x: Self.width - 2, y: raster.size.height - 2))
      #expect(opened.count == 1)
    }

    @Test("A long press lays selectable TextKit 2 text over the drawing, and a tap ends it")
    func selection() throws {
      let run = try run()
      let (view, window) = try shown(run)
      defer { window.close() }
      view.beginSelecting(at: CGPoint(x: 12, y: view.raster.topInset + 10))
      let live = try #require(view.live)
      #expect(live.textLayoutManager != nil)
      #expect(live.text == run.text.string)
      let selected = Range(live.selectedRange, in: live.text).map { String(live.text[$0]) }
      #expect(selected == "Read")
      // The drawing shows through: the live text's glyphs are clear.
      // No range is asked for, so the out-pointer is nil.
      let color = unsafe live.attributedText.attribute(
        .foregroundColor, at: 0, effectiveRange: nil)
      #expect((color as? UIColor) == .clear)
      #expect(view.image.showsDrawing)
      view.tap(at: CGPoint(x: 1, y: 1))
      #expect(view.live == nil)
    }
  }
#endif
