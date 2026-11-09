#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Dragging cards and pinching the board.
  @Suite("Canvas gestures", .serialized)
  @MainActor
  struct CanvasGestureGapsTests {
    private let board = CanvasBoard(id: "main", name: "Main")

    private func card(_ id: String, left: Int = 0, top: Int = 0) -> CanvasCard {
      CanvasCard(
        id: id, title: id, state: .idle, workspace: "/repo", branch: nil, left: left, top: top)
    }

    private func page(_ cards: [CanvasCard], _ actions: CanvasActions = CanvasActions())
      -> OffscreenWindow<CanvasView>
    {
      OffscreenWindow(
        CanvasView(
          state: CanvasViewState(boards: [board], activeBoard: "main", cards: cards),
          actions: actions), width: 900, height: 700)
    }

    /// Clicks across the board until `open` reports the card, and returns where.
    private func findCard(
      _ screen: OffscreenWindow<CanvasView>, opened: () -> Bool
    ) throws -> CGPoint {
      for row in stride(from: 160, to: 680, by: 60) {
        for column in stride(from: 40, to: 880, by: 80) {
          let point = CGPoint(x: column, y: row)
          try screen.click(point)
          if opened() { return point }
        }
      }
      throw OffscreenWindowError.notFound("the card")
    }

    @Test("Dragging a card reports where it lands, once, and a click still opens it")
    func dragCard() throws {
      var moves: [String] = []
      var opened: [String] = []
      var actions = CanvasActions()
      actions.move = { moves.append("\($0) \($1) \($2)") }
      actions.open = { opened.append($0) }
      let screen = page([card("a")], actions)
      defer { screen.close() }
      let point = try findCard(screen) { !opened.isEmpty }
      #expect(moves.isEmpty, "a click isn't a drag")
      try screen.dragGesture(from: point, to: CGPoint(x: point.x + 90, y: point.y + 40))
      let left = CanvasGeometry.moved(0, by: 90)
      let top = CanvasGeometry.moved(0, by: 40)
      #expect(moves == ["a \(left) \(top)"])
      #expect(opened == ["a"], "a drag doesn't open it")
    }

    @Test("Pinching zooms the board, and the fit no longer follows the cards")
    func pinchZooms() throws {
      let cards = [card("a"), card("b", left: 3_000, top: 2_000)]
      let screen = page(cards)
      defer { screen.close() }
      func boardWidth() throws -> CGFloat {
        let scroll = try #require(
          screen.allViews.compactMap { $0 as? NSScrollView }.max {
            $0.frame.height < $1.frame.height
          })
        return try #require(scroll.documentView).frame.width
      }
      let fitted = try boardWidth()
      screen.pinch(at: CGPoint(x: 450, y: 400), amounts: [0.5, 0.5, 1])
      let zoomed = try boardWidth()
      #expect(zoomed > fitted)
      screen.pinch(at: CGPoint(x: 450, y: 400), amounts: [-0.5])
      #expect(try boardWidth() < zoomed, "a new pinch starts from where the last one ended")
    }
  }
#endif
