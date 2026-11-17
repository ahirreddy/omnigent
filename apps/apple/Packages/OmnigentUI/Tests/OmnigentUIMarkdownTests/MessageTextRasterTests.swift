#if os(macOS)
  import AppKit
  import IOSurface
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
      let surface = try #require(raster.surface)
      _ = unsafe surface.lock(options: .readOnly, seed: nil)
      defer { _ = unsafe surface.unlock(options: .readOnly, seed: nil) }
      let column = Int(point.x * raster.scale)
      let line = Int(point.y * raster.scale)
      // Premultiplied BGRA, little-endian: alpha is the fourth byte.
      let offset = line * surface.bytesPerRow + column * 4 + 3
      return unsafe surface.baseAddress.load(fromByteOffset: offset, as: UInt8.self)
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
      let surface = try #require(drawn.surface)
      #expect(surface.width == 1000)
      #expect(surface.height == Int(((drawn.size.height - drawn.topInset) * 2).rounded(.up)))
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

    /// The bytes of `raster`'s bitmap inside `rect` (in the run's text coordinates).
    private func pixels(in rect: CGRect, of raster: MessageTextRaster) throws -> [UInt8] {
      let surface = try #require(raster.surface)
      _ = unsafe surface.lock(options: .readOnly, seed: nil)
      defer { _ = unsafe surface.unlock(options: .readOnly, seed: nil) }
      var bytes: [UInt8] = []
      for line in Int(rect.minY * raster.scale)..<Int(rect.maxY * raster.scale) {
        for column in Int(rect.minX * raster.scale)..<Int(rect.maxX * raster.scale) {
          for channel in 0..<4 {
            let offset = line * surface.bytesPerRow + column * 4 + channel
            bytes.append(unsafe surface.baseAddress.load(fromByteOffset: offset, as: UInt8.self))
          }
        }
      }
      return bytes
    }

    @Test("A drawn run draws its controls at rest, and makes them as views only when reached")
    func controlsDrawnAtRest() throws {
      let palette = MessageTextPalette(MessageTextFixture.style)
      let stamps = MessageTextChromeStamps.stamps(for: palette, scale: 2)
      let code = try #require(stamps.code, "the code header's controls draw in a stamp")
      #expect(stamps.table != nil, "the table's controls draw in a stamp")
      var stamped = style
      stamped.codeChrome = code
      stamped.tableChrome = stamps.table
      let document = MessageTextFixture.document("Intro line.\n\n```swift\nlet a = 1\n```")
      let plain = MessageTextRaster.make(document.run, width: 500, scale: 2, style: style)
      let drawn = MessageTextRaster.make(document.run, width: 500, scale: 2, style: stamped)
      let (block, header) = try #require(drawn.chromeFrames.first)
      #expect(drawn.drawnChrome == [block])
      #expect(plain.drawnChrome.isEmpty)
      // The controls sit at the header's trailing edge, over its band.
      let controls = CGRect(
        x: header.maxX - 120, y: header.minY, width: 120, height: header.height)
      #expect(try pixels(in: controls, of: drawn) != pixels(in: controls, of: plain))
      let view = MessageTextRasterView(document: document, raster: drawn)
      #expect(view.chromeViews.isEmpty, "nothing is made until the pointer reaches it")
      #expect(view.makeChrome(block) is MessageCodeHeaderView)
      // Without a stamp, a run makes its controls at once, as before.
      let eager = MessageTextRasterView(document: document, raster: plain)
      #expect(eager.chromeViews[block] is MessageCodeHeaderView)
    }

    @Test("A drawn run lets its bitmap go off screen and takes a drawing back")
    func releasesBitmap() throws {
      let document = MessageTextFixture.document(Self.answer)
      let drawn = raster(document, width: 500, scale: 2)
      let view = MessageTextRasterView(document: document, raster: drawn)
      view.releaseBitmap()
      #expect(view.isReleased)
      #expect(view.raster.surface == nil)
      #expect(view.raster.size == drawn.size, "it keeps its size and links")
      #expect(view.raster.links == drawn.links)
      view.show(drawn)
      #expect(!view.isReleased)
      #expect(view.raster === drawn)
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
