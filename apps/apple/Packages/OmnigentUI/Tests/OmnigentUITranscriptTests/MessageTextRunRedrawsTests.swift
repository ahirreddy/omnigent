#if os(iOS)
  import Foundation
  import Testing

  @testable import OmnigentUIComponents

  /// Drawing the runs text rows show at a new width off the main actor: the order requests go
  /// in, and how a drawing reaches the rows that asked for it.
  @Suite("Message text run redraws")
  @MainActor
  struct MessageTextRunRedrawsTests {
    /// A message's document, built in `style`.
    private func document(_ text: String, style: TranscriptCollectionTextStyle) throws
      -> MessageTextDocument
    {
      var builder = MessageTextBuilder(palette: try #require(style.palette))
      return builder.document(MarkdownParser.parse(text))
    }

    private func key(_ document: MessageTextDocument, width: CGFloat) -> MessageTextRasterKey {
      MessageTextRasterKey(document: document.serial, width: width, scale: 2)
    }

    @Test("Runs drawn again at a new width go nearest the reader first; a stale width goes")
    func order() throws {
      let style = textRowStyle()
      let raster = try #require(style.rasterStyle)
      // With no workers the requests wait, in the order they would go.
      let redraws = MessageTextRunRedraws(workers: 0)
      let far = try document("Far below.", style: style)
      let near = try document("Just below.", style: style)
      let above = try document("Above.", style: style)
      redraws.focus(at: 1000)
      redraws.draw(far, as: key(far, width: 300), style: raster, at: 3000) { _ in }
      redraws.draw(near, as: key(near, width: 280), style: raster, at: 1100) { _ in }
      redraws.draw(above, as: key(above, width: 300), style: raster, at: 700) { _ in }
      // The window turned again before the near run was drawn: only its newest width is wanted.
      redraws.draw(near, as: key(near, width: 300), style: raster, at: 1100) { _ in }
      let waiting = redraws.waitingKeys
      #expect(waiting.map(\.document) == [near.serial, above.serial, far.serial])
      #expect(waiting.allSatisfy { $0.width == 300 })
    }

    @Test("A run drawn again lands on the main actor, kept with its size, once for every ask")
    func lands() async throws {
      let style = textRowStyle()
      let raster = try #require(style.rasterStyle)
      let rasters = MessageTextRasters(byteLimit: 64 << 20)
      let sizes = MessageTextSizes(limit: 64)
      let redraws = MessageTextRunRedraws(workers: 2, rasters: rasters, sizes: sizes)
      let run = try document("Drawn **again** at the new width.", style: style)
      let landings = Landings()
      for _ in 0..<2 {
        redraws.draw(run, as: key(run, width: 320), style: raster, at: 0) {
          landings.widths.append($0.width)
        }
      }
      for _ in 0..<200 where landings.widths.count < 2 {
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(landings.widths == [320, 320])
      #expect(rasters.contains(key(run, width: 320)))
      #expect(sizes.size(document: run.serial, width: 320) != nil)
      #expect(redraws.waitingKeys.isEmpty)
    }
  }

  /// The widths of drawings handed to the main actor.
  @MainActor
  private final class Landings {
    var widths: [CGFloat] = []
  }
#endif
