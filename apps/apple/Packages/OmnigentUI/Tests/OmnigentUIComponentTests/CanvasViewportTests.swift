#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The board's view as the user moves it: a resize keeps its middle, and a pan by the scroll
  /// view itself (a wheel or trackpad) counts in the remembered view, as a drag pan does.
  @Suite("Canvas viewport", .serialized)
  @MainActor
  struct CanvasViewportTests {
    /// The board for the tab chosen: Main holds the cards, Project none.
    private struct Host: View {
      let cards: [CanvasCard]
      @State private var active = "main"

      var body: some View {
        var actions = CanvasActions()
        actions.selectBoard = { active = $0 }
        return CanvasView(
          state: CanvasViewState(
            boards: [
              CanvasBoard(id: "main", name: "Main"), CanvasBoard(id: "p", name: "Project"),
            ],
            activeBoard: active, cards: active == "main" ? cards : []),
          actions: actions)
      }
    }

    private func card(_ id: String, left: Int = 0, top: Int = 0) -> CanvasCard {
      CanvasCard(
        id: id, title: id, state: .idle, workspace: "/repo", branch: nil, left: left, top: top)
    }

    private func board(_ screen: OffscreenWindow<Host>) throws -> NSScrollView {
      try #require(
        screen.allViews.compactMap { $0 as? NSScrollView }.max {
          $0.frame.height < $1.frame.height
        })
    }

    /// Scrolls the board's own scroll view, as a wheel or trackpad does.
    private func scroll(_ screen: OffscreenWindow<Host>, to point: CGPoint) throws {
      let view = try board(screen)
      view.contentView.scroll(to: point)
      view.reflectScrolledClipView(view.contentView)
      screen.settle(0.1)
    }

    @Test("A pan by the scroll view comes back with its board, as a drag pan does")
    func wheelPanIsRemembered() async throws {
      // So far apart that even the fit, at the smallest zoom, scrolls.
      let screen = OffscreenWindow(
        Host(cards: [card("a"), card("b", left: 400_000)]), width: 900, height: 700)
      defer { screen.close() }
      try scroll(screen, to: CGPoint(x: 6_000, y: 0))
      let panned = try board(screen).contentView.bounds.origin.x
      #expect(panned > 1_000)
      try screen.clickElement("canvas-board-p")
      try screen.clickElement("canvas-board-main")
      let restored = try await screen.waitUntil(timeout: .seconds(3)) {
        abs(try board(screen).contentView.bounds.origin.x - panned) < 2
      }
      let origin = try board(screen).contentView.bounds.origin
      #expect(restored, "Main came back at \(origin)")
    }

    @Test("A resize keeps the middle of a view the user moved")
    func resizeKeepsTheMiddle() throws {
      let screen = OffscreenWindow(
        Host(cards: [card("a"), card("b", left: 64_000, top: 32_000)]), width: 900, height: 700)
      defer { screen.close() }
      // Zoom in, Zoom out and Fit view close the key loop (no reset or new session here).
      try screen.clickControl(at: screen.controlFrames.count - 3)
      try screen.clickControl(at: screen.controlFrames.count - 3)
      try scroll(screen, to: CGPoint(x: 1_500, y: 800))
      let before = try board(screen).contentView.bounds
      screen.window.setContentSize(CGSize(width: 1_100, height: 600))
      screen.settle(0.3)
      let after = try board(screen).contentView.bounds
      #expect(abs(after.midX - before.midX) < 2, "\(before) then \(after)")
      #expect(abs(after.midY - before.midY) < 2, "\(before) then \(after)")
    }
  }
#endif
