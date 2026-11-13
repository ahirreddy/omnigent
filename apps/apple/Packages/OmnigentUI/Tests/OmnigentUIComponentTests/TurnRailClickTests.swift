#if os(macOS)
  import AppKit
  import Observation
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// What the rail's host captures in the jump it hands the rail, and the jumps it heard.
  @MainActor
  @Observable
  private final class RailJumpTarget {
    var name = "first"
    @ObservationIgnored var jumps: [String] = []
    @ObservationIgnored var olderLoads = 0
  }

  /// A transcript's stand-in: it gives the rail a new jump whenever `name` changes, and nothing
  /// else about the ticks changes with it.
  private struct RailHost: View {
    let target: RailJumpTarget
    let model: TurnRailModel

    var body: some View {
      let name = target.name
      TurnRail(
        model: model, jump: { target.jumps.append("\(name) \($0)") }, preview: { _ in "" },
        loadOlder: { target.olderLoads += 1 }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  @Suite("Turn rail: clicks", .serialized)
  @MainActor
  struct TurnRailClickTests {
    /// The middle of a tick, from the rail's top left.
    private func tick(_ index: Int) -> CGPoint {
      CGPoint(
        x: Theme.Spacing.small + 8,
        y: TurnRail.fade + (CGFloat(index) + 0.5) * TurnRail.pitch)
    }

    @Test("a tick jumps with the transcript's latest jump, not the one it was built with")
    func tickUsesTheLatestJump() throws {
      let target = RailJumpTarget()
      let model = TurnRailModel()
      model.setTurns([
        TranscriptTurn(id: "u1", text: "Fix the bug"),
        TranscriptTurn(id: "u2", text: "And add tests"),
        TranscriptTurn(id: "u3", text: "Ship it"),
      ])
      let screen = OffscreenWindow(RailHost(target: target, model: model), width: 400, height: 300)
      defer { screen.close() }

      try screen.click(tick(1))
      #expect(target.jumps == ["first u2"])

      // Only the jump is new: the ticks' turns, hover and active turn are as they were.
      target.name = "second"
      screen.settle()
      try screen.click(tick(1))
      try screen.click(tick(2))
      #expect(target.jumps == ["first u2", "second u2", "second u3"])
    }

    @Test("the rail is as wide as the rows' gutter, so a click on a row's start is not a tick's")
    func railStaysInTheGutter() throws {
      let target = RailJumpTarget()
      let model = TurnRailModel()
      model.setTurns([
        TranscriptTurn(id: "u1", text: "Fix the bug"),
        TranscriptTurn(id: "u2", text: "And add tests"),
      ])
      let screen = OffscreenWindow(RailHost(target: target, model: model), width: 400, height: 300)
      defer { screen.close() }

      // Where a row's text starts in a pane no wider than its column.
      try screen.click(CGPoint(x: Theme.Spacing.gutter + 1, y: tick(1).y))
      #expect(target.jumps.isEmpty)
      try screen.click(CGPoint(x: Theme.Spacing.gutter - 1, y: tick(1).y))
      #expect(target.jumps == ["first u2"])
    }

    @Test("scrolling the rail up to its top pages in older history; a layout's move does not")
    func scrollingToTheTopLoadsOlder() throws {
      let target = RailJumpTarget()
      let model = TurnRailModel()
      model.setTurns((0..<80).map { TranscriptTurn(id: "u\($0)", text: "Turn \($0)") })
      let screen = OffscreenWindow(RailHost(target: target, model: model), width: 400, height: 400)
      defer { screen.close() }
      let rail = try #require(screen.allViews.compactMap { $0 as? NSScrollView }.first)
      func scroll(to offset: CGFloat) {
        rail.contentView.scroll(to: NSPoint(x: 0, y: offset))
        rail.reflectScrolledClipView(rail.contentView)
        screen.settle()
      }
      scroll(to: 200)
      scroll(to: 0)
      #expect(target.olderLoads == 0, "nobody is scrolling the rail")

      scroll(to: 200)
      screen.liveScroll(rail, began: true)
      scroll(to: 0)
      screen.liveScroll(rail, began: false)
      #expect(target.olderLoads > 0)
    }
  }
#endif
