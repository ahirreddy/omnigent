#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// While a window resizes, a frame holds layout passes that disagree by a point. Reporting
  /// positions flips them within the frame: SwiftUI logs "Geometry action is cycling between
  /// duplicate values" and the dock's state updates for nothing.
  @Suite("Decision surfaces in a window being resized", .serialized)
  @MainActor
  struct DecisionSurfaceGeometryTests {
    /// A card under a spacer of `above` points, in a scroll view over a bar.
    private struct Column: View {
      let surfaces: DecisionSurfaces
      let above: CGFloat
      let bar: CGFloat

      var body: some View {
        ScrollView {
          VStack(spacing: 0) {
            Color.gray.frame(height: above)
            Color.red.frame(height: 200).reportsInlineDecision("card", showsApprove: true)
          }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) { Color.blue.frame(height: bar) }
        .environment(surfaces)
      }
    }

    /// The real conversation with a decision, the state chaos runs saw the fault in.
    private struct Conversation: View {
      var body: some View {
        GalleryConversation(state: Self.state, composer: PreviewData.composerRunning)
      }

      private static var state: ConversationViewState {
        var state = PreviewData.conversation
        state.decisions = [PreviewData.codexCommand]
        return state
      }
    }

    /// Lines the decision surfaces have logged and the trace still holds.
    private func decisionChanges() -> Int {
      HangTrace.report(since: [:]).components(separatedBy: "\n").count { $0.contains("decision ") }
    }

    @Test("A card under the bar isn't on screen, and one above it is")
    func viewportEndsAtTheBar() {
      let surfaces = DecisionSurfaces()
      let screen = OffscreenWindow(
        Column(surfaces: surfaces, above: 20, bar: 100), width: 400, height: 400)
      defer { screen.close() }
      screen.settle()
      #expect(surfaces.visibility.onScreen == ["card"])
      #expect(surfaces.visibility.approvable == ["card"])

      let covered = DecisionSurfaces()
      let coveredScreen = OffscreenWindow(
        Column(surfaces: covered, above: 305, bar: 100), width: 400, height: 400)
      defer { coveredScreen.close() }
      coveredScreen.settle()
      #expect(covered.visibility.onScreen.isEmpty, "the bar covers all but a sliver of it")
    }

    @Test("A window resizing a point at a time updates nothing about a conversation's decisions")
    func resizingReportsNothing() {
      HangTrace.isEnabled = true
      LoopProbe.sink = { _ in }
      defer {
        LoopProbe.sink = nil
        HangTrace.isEnabled = false
      }
      let screen = OffscreenWindow(Conversation(), width: 800, height: 600)
      defer { screen.close() }
      screen.settle()
      // Pushes what settling logged out of the trace, which keeps only the latest changes.
      for _ in 0..<(HangTrace.keptChanges * 2) { HangTrace.change("settled") }
      for height: CGFloat in [601, 600, 601, 600, 601] {
        var frame = screen.window.frame
        frame.size.height = height
        screen.window.setFrame(frame, display: true)
        screen.settle(0.02)
      }
      #expect(decisionChanges() == 0)
    }
  }
#endif
