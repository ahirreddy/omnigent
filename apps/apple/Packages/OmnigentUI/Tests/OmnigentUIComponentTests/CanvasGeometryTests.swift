import CoreGraphics
import Testing

@testable import OmnigentUIComponents

@Suite("Canvas geometry")
struct CanvasGeometryTests {
  private func card(_ id: String, left: Int, top: Int) -> CanvasCard {
    CanvasCard(id: id, title: id, state: .idle, workspace: "/repo", left: left, top: top)
  }

  @Test("The content spans every card plus a margin, wherever the cards sit")
  func bounds() {
    let geometry = CanvasGeometry(cards: [
      card("a", left: -320, top: 0), card("b", left: 320, top: 160),
    ])
    #expect(geometry.origin == CGPoint(x: -384, y: -64))
    #expect(geometry.size == CGSize(width: 640 + 280 + 128, height: 160 + 132 + 128))
    #expect(geometry.offset(of: card("a", left: -320, top: 0)) == CGSize(width: 64, height: 64))
  }

  @Test("Fitting never zooms past 1 and stays within the zoom range")
  func fit() {
    let geometry = CanvasGeometry(cards: [
      card("a", left: 0, top: 0), card("b", left: 3_200, top: 0),
    ])
    #expect(geometry.fitZoom(CGSize(width: 10_000, height: 10_000)) == 1)
    let zoom = geometry.fitZoom(CGSize(width: geometry.size.width / 2, height: 10_000))
    #expect(abs(zoom - 0.5) < 0.0001)
    #expect(geometry.fitZoom(CGSize(width: 1, height: 1)) == CanvasGeometry.minZoom)
    #expect(geometry.fitZoom(.zero) == 1)
  }
}
