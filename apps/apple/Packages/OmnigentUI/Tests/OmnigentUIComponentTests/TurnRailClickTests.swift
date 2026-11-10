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
        loadOlder: {}
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
  }
#endif
