#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// Message runs drawn ahead into bitmaps: their size and links match the live text view's,
  /// they draw the right way up, and the cache keeps them under its budget.
  @MainActor
  @Suite("Message text drawn ahead", .serialized)
  struct MessageTextRasterTests {
    private static let answer = """
      ## Step 3

      A paragraph with `code` and [a link](https://example.com/a).

      ```swift
      let a = 1
      let b = 2
      ```

      > A quote to close.
      """

    private var style: MessageTextRasterStyle {
      let palette = MessageTextPalette(MessageTextFixture.style)
      return MessageTextRasterStyle(
        codeSurface: palette.codeSurface.cgColor, codeHeader: palette.hover.cgColor,
        separator: palette.separator.cgColor, border: palette.border.cgColor,
        quoteBar: palette.tertiary.cgColor, link: palette.link.cgColor, codeRadius: 16)
    }

    private func raster(_ document: MessageTextDocument, width: CGFloat, scale: CGFloat)
      -> MessageTextRaster
    {
      MessageTextRaster.make(document.run, width: width, scale: scale, style: style)
    }

    /// The alpha of the pixel at `point` (in points, from the top left).
    private func alpha(at point: CGPoint, in raster: MessageTextRaster) throws -> UInt8 {
      let image = try #require(raster.image)
      let data = try #require(image.dataProvider?.data as Data?)
      let column = Int(point.x * raster.scale)
      let line = Int(point.y * raster.scale)
      // Premultiplied BGRA, little-endian: alpha is the fourth byte.
      return data[line * image.bytesPerRow + column * 4 + 3]
    }

    @Test("A drawn run measures and links as the live text view does at its width")
    func matchesTheTextView() throws {
      let document = MessageTextFixture.document(Self.answer)
      let drawn = raster(document, width: 500, scale: 2)
      let view = MessageTextContentView(document: document)
      let measured = view.measurement(for: 500)
      #expect(drawn.size == MessageTextSize(height: measured.height, usedWidth: measured.usedWidth))
      #expect(drawn.links.map(\.url) == view.linkRects.map(\.url))
      #expect(drawn.links.map(\.rect) == view.linkRects.map(\.rect))
      let image = try #require(drawn.image)
      #expect(image.width == 1000)
      #expect(image.height == Int(((drawn.size.height - drawn.topInset) * 2).rounded(.up)))
      #expect(!drawn.chromeFrames.isEmpty, "the code block's header has a place")
    }

    @Test("The bitmap is drawn top down: the code block's surface lies under its header")
    func drawsUpright() throws {
      let document = MessageTextFixture.document("Intro line.\n\n```swift\nlet a = 1\n```")
      let drawn = raster(document, width: 400, scale: 1)
      let header = try #require(drawn.chromeFrames.values.first)
      // Inside the code block, below its header band: the opaque surface.
      #expect(try alpha(at: CGPoint(x: 200, y: header.maxY + 8), in: drawn) > 0)
      // Above the block, right of the short intro line: nothing drawn.
      #expect(try alpha(at: CGPoint(x: 390, y: 4), in: drawn) == 0)
    }

    @Test("The cache keeps rasters under its budget, the least recently shown going first")
    func cacheBudget() {
      let document = MessageTextFixture.document("One line of text.")
      let one = raster(document, width: 300, scale: 1)
      let rasters = MessageTextRasters(byteLimit: one.byteCount * 2)
      let keys = (0..<3).map { MessageTextRasterKey(document: UInt64($0), width: 300, scale: 1) }
      rasters.store(one, for: keys[0])
      rasters.store(raster(document, width: 300, scale: 1), for: keys[1])
      _ = rasters.raster(for: keys[0])
      rasters.store(raster(document, width: 300, scale: 1), for: keys[2])
      #expect(rasters.contains(keys[0]), "shown last, so kept")
      #expect(!rasters.contains(keys[1]))
      #expect(rasters.contains(keys[2]))
      #expect(rasters.byteCount <= one.byteCount * 2)
    }

    @Test("A note without drawing keeps the prewarm drawing ahead; another width does not")
    func noteKeepsDrawing() {
      let prewarm = MessageTextPrewarm(limit: 4, rasters: MessageTextRasters(byteLimit: 1 << 20))
      let palette = MessageTextPalette(MessageTextFixture.style)
      prewarm.note(palette: palette, width: 500, scale: 2, raster: style)
      #expect(prewarm.drawsAhead)
      prewarm.note(palette: palette, width: 500)
      #expect(prewarm.drawsAhead, "a SwiftUI row's note at the same width")
      prewarm.note(palette: palette, width: 400)
      #expect(!prewarm.drawsAhead)
    }

    @Test("The prewarm draws the answers asked for ahead, and only lays the others out")
    func drawsWhatIsAskedFor() async throws {
      let rasters = MessageTextRasters(byteLimit: 64 << 20)
      let prewarm = MessageTextPrewarm(limit: 8, rasters: rasters)
      let palette = MessageTextPalette(MessageTextFixture.style)
      prewarm.note(palette: palette, width: 500, scale: 1, raster: style)
      let offered = "An answer offered by the warmup, far from the reader."
      let asked = "An answer about to scroll into view."
      prewarm.offer(offered)
      prewarm.prioritize([asked])
      func document(_ text: String) -> MessageTextDocument? {
        prewarm.takeDocument(
          for: MessageTextDocumentKey(
            text: text, piece: 0, style: MessageTextFixture.style, linked: []))
      }
      for _ in 0..<400 where document(offered) == nil || document(asked) == nil {
        try await Task.sleep(for: .milliseconds(10))
      }
      let drawnKey = { (text: String) -> MessageTextRasterKey? in
        document(text).map { MessageTextRasterKey(document: $0.serial, width: 500, scale: 1) }
      }
      #expect(try rasters.contains(#require(drawnKey(asked))))
      #expect(try !rasters.contains(#require(drawnKey(offered))))
    }

    @Test("A press in a drawn run lays the live text view over it, and it goes once done")
    func liveOverlay() throws {
      let document = MessageTextFixture.document(Self.answer)
      let drawn = raster(document, width: 500, scale: 2)
      let view = MessageTextRasterView(document: document, raster: drawn)
      view.frame = CGRect(x: 0, y: 0, width: 500, height: drawn.size.height)
      view.layoutSubtreeIfNeeded()
      #expect(view.live == nil)
      let live = view.activate()
      #expect(view.live === live)
      #expect(live.frame == view.bounds)
      #expect(live.measurement(for: 500).height == drawn.size.height)
      view.deactivate()
      #expect(view.live == nil)
      let parent = unsafe live.superview
      #expect(parent == nil)
    }
  }
#endif
