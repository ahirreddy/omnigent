#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// "Sub-agent of", "Side chat of" and "Created by" sit over the transcript's top edge.
  @Suite("The session origin bar", .serialized)
  @MainActor
  struct SessionOriginBarTests {
    @Test("It is a bar: what scrolls under it does not show through")
    func opaque() throws {
      let bar = SessionOriginBar(
        relation: .subagentOf, origin: CreatingSession(id: "o", title: "Parent"), open: { _ in })
      let width: CGFloat = 300
      let rendered = try RenderSupport.render(
        ZStack(alignment: .top) {
          // Pure red: the system's red is not.
          Color(red: 1, green: 0, blue: 0)
          bar
        }
        .omnigentTheme(.graphite), width: width, height: 120, scheme: .dark, layout: .regular)
      func color(at point: CGPoint) throws -> NSColor {
        let image = rendered.image
        let scale = CGFloat(image.pixelsWide) / width
        return try #require(
          image.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?
            .usingColorSpace(.deviceRGB))
      }
      // In the bar's empty trailing part, the canvas; below the bar, what it sits over.
      let inBar = try color(at: CGPoint(x: 280, y: 10))
      #expect(inBar.redComponent < 0.2 && inBar.alphaComponent == 1, "\(inBar)")
      let below = try color(at: CGPoint(x: 280, y: 100))
      #expect(below.redComponent > 0.8 && below.greenComponent < 0.3, "\(below)")
    }
  }
#endif
