#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Looping indicators draw with Core Animation; still, they must look like the SwiftUI marks
  /// they replace.
  @Suite("Looping indicators draw like their still marks")
  @MainActor
  struct LoopingIndicatorRenderTests {
    /// The bounding box, in pixels, of pixels brighter than the background in the left gutter.
    static func markBounds(_ rendered: RenderSupport.Rendered, gutter: Int) -> CGRect? {
      let image = rendered.image
      var minX = Int.max
      var minY = Int.max
      var maxX = -1
      var maxY = -1
      for row in 0..<image.pixelsHigh {
        for column in 0..<min(gutter, image.pixelsWide) {
          guard let color = image.colorAt(x: column, y: row), color.brightnessComponent > 0.35
          else {
            continue
          }
          minX = min(minX, column)
          minY = min(minY, row)
          maxX = max(maxX, column)
          maxY = max(maxY, row)
        }
      }
      guard maxX >= 0 else { return nil }
      return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    @Test("a live CLI bullet sits where the still bullet does")
    func liveBulletMatchesStill() throws {
      var line = CLILineText()
      line.append("Working", bold: true)
      func render(isLive: Bool) throws -> RenderSupport.Rendered {
        let view = CLIBulletLine(line: line, isLive: isLive)
          .transcriptColumn()
          .cliPalette()
        let rendered = try RenderSupport.render(
          view, width: 320, scheme: .dark, layout: .regular)
        try RenderSupport.write(rendered, name: "cli-bullet-\(isLive ? "live" : "still")")
        return rendered
      }
      let still = try #require(Self.markBounds(try render(isLive: false), gutter: 40))
      let live = try #require(Self.markBounds(try render(isLive: true), gutter: 40))
      #expect(abs(still.midX - live.midX) <= 2, "\(still) \(live)")
      #expect(abs(still.midY - live.midY) <= 2, "\(still) \(live)")
      #expect(abs(still.width - live.width) <= 2, "\(still) \(live)")
    }
  }
#endif
