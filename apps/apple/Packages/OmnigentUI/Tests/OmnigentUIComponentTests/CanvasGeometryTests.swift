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

  @Test("A dragged card is drawn where it would land: the core's grid point, halves up")
  func snapsWhileDragging() {
    // The core's own cases: (47, 48) lands on (32, 64) and (-16, -17) on (0, -32).
    #expect(CanvasGeometry.snapped(0, by: 47) == 32)
    #expect(CanvasGeometry.snapped(0, by: 48) == 64)
    #expect(CanvasGeometry.snapped(0, by: -16) == 0)
    #expect(CanvasGeometry.snapped(0, by: -17) == -32)
    #expect(CanvasGeometry.snapped(320, by: 15.4) == 320)
    #expect(CanvasGeometry.snapped(.max, by: 10) == CanvasGeometry.maxCoordinate)
    #expect(CanvasGeometry.snapped(.min, by: .nan) == -CanvasGeometry.maxCoordinate)
    #expect(
      CanvasGeometry.snappedOffset(left: 64, top: 0, by: CGSize(width: 50, height: -20))
        == CGSize(width: 64, height: -32))
  }

  @Test("A resize keeps the view's middle where it was")
  func recenters() {
    let origin = CGPoint(x: 500, y: 300)
    #expect(
      CanvasGeometry.recentered(
        origin, from: CGSize(width: 800, height: 600), to: CGSize(width: 1_000, height: 500))
        == CGPoint(x: 400, y: 350))
    #expect(
      CanvasGeometry.recentered(
        CGPoint(x: 20, y: 0), from: CGSize(width: 800, height: 600),
        to: CGSize(width: 1_200, height: 600)) == .zero,
      "never before the content's start")
  }

  @Test("Only a scroll the board's own layout didn't cause is the user's")
  func userScrolls() {
    let content = CGSize(width: 4_000, height: 3_000)
    let view = CGSize(width: 800, height: 600)
    func scroll(_ left: CGFloat, _ top: CGFloat, content: CGSize = content) -> CanvasScroll {
      CanvasScroll(
        offset: CGPoint(x: left, y: top), content: content, container: view,
        visible: CGRect(x: left, y: top, width: view.width, height: view.height))
    }
    #expect(CanvasGeometry.isUserScroll(from: scroll(0, 0), to: scroll(0, 120)))
    #expect(!CanvasGeometry.isUserScroll(from: scroll(0, 0), to: scroll(0, 0)))
    #expect(
      !CanvasGeometry.isUserScroll(
        from: scroll(0, 0), to: scroll(40, 0, content: CGSize(width: 5_000, height: 3_000))),
      "a zoom changes the content")
    let small = CGSize(width: 1_000, height: 700)
    #expect(
      !CanvasGeometry.isUserScroll(
        from: scroll(900, 600, content: small), to: scroll(200, 100, content: small)),
      "a clamp into a smaller range")
  }
}
