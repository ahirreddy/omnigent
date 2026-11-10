#if os(macOS)
  import AppKit
  import Observation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The pane a transcript sits in: its width and the dock under it, which a test changes as a
  /// resize and a growing composer do.
  @MainActor
  @Observable
  private final class TranscriptPane {
    var width: CGFloat
    var dock: CGFloat

    init(width: CGFloat, dock: CGFloat) {
      self.width = width
      self.dock = dock
    }
  }

  /// The transcript over a dock that insets it, as the conversation screen lays it out.
  private struct DockedTranscriptHost: View {
    let conversation: LiveConversation
    let pane: TranscriptPane

    var body: some View {
      LiveTranscriptHost(conversation: conversation, actions: ConversationActions())
        .safeAreaBar(edge: .bottom, spacing: 0) { Color.clear.frame(height: pane.dock) }
        .frame(width: pane.width)
    }
  }

  /// What layout did to a transcript while nothing new arrived.
  private struct Churn: CustomStringConvertible {
    var heights = 0
    var scrolls = 0
    var refused = 0

    var description: String { "heights \(heights), scrolls \(scrolls), refused \(refused)" }
  }

  @Suite("Transcript layout churn", .serialized)
  @MainActor
  struct TranscriptLayoutChurnTests {
    private static let wide: CGFloat = 900
    private static let height: CGFloat = 220
    /// The widths a dragged window passes through in ``resize(_:in:)``.
    private static let dragSteps = 40

    /// Turns whose rows differ widely in height, so the lazy rows' estimates are far off.
    private func unevenSession(turns: Int) -> LiveConversation {
      let rows = (0..<turns).flatMap { index -> [Row] in
        let lines = 1 + (index * 37) % 23
        let answer = (0..<lines).map {
          "Line \($0) of answer \(index), long enough to wrap in a narrow pane and not a wide one."
        }
        var turn = [
          TranscriptFixture.user(
            "u\(index)", String(repeating: "Question \(index). ", count: 1 + index % 9))
        ]
        if index.isMultiple(of: 3) {
          turn.append(TranscriptFixture.toolCall("t\(index)"))
          turn.append(TranscriptFixture.toolResult("tr\(index)", callID: "t\(index)"))
        }
        turn.append(
          TranscriptFixture.answer(
            "a\(index)", answer.joined(separator: "\n\n"), responseID: "r\(index)"))
        return turn
      }
      return LiveConversation(ConversationViewState(header: TranscriptFixture.header, rows: rows))
    }

    private func plan() -> EventSection {
      EventSection(
        id: "todos", title: "Plan", summary: "1 of 3",
        details: [
          DetailSection(id: "t1", title: "completed", text: "Read the code"),
          DetailSection(id: "t2", title: "pending", text: "Fix the bug"),
          DetailSection(id: "t3", title: "pending", text: "Test the fix"),
        ])
    }

    /// What layout did since `before`.
    private func churn(since before: HangTrace.Tallies) -> Churn {
      let now = HangTrace.tallies()
      func added(_ name: String) -> Int { now.count(name, since: before) }
      return Churn(
        heights: added("transcript content height"), scrolls: added("transcript layout scroll"),
        refused: added("transcript scroll refused"))
    }

    /// A following reader's transcript in a short pane, built with `limits`.
    private func shortPane(
      _ pane: TranscriptPane, _ conversation: LiveConversation,
      limits: LayoutScrollBudget.Limits = .init()
    ) async throws -> OffscreenWindow<AnyView> {
      TranscriptScrollState.layoutScrollLimits = limits
      let window = transcriptScreen(
        DockedTranscriptHost(conversation: conversation, pane: pane), width: Self.wide,
        height: Self.height)
      TranscriptScrollState.layoutScrollLimits = .init()
      try await letTasksRun(window, milliseconds: 300)
      conversation.scrollRequest += 1
      try await letTasksRun(window, milliseconds: 300)
      return window
    }

    /// Changes the pane's size many times a frame apart, as dragging a window's corner does.
    private func resize(_ pane: TranscriptPane, in window: OffscreenWindow<AnyView>) {
      for index in 0..<Self.dragSteps {
        pane.width = 380 + CGFloat((index * 53) % 400)
        pane.dock = 40 + CGFloat((index * 17) % 130)
        window.settle(0.016)
      }
    }

    /// The hang this looks for kept laying the transcript out with nothing arriving. It did not
    /// show here with the limits lifted either: after each change layout was still again. With
    /// limits, a short quiet time has any scroll that waits for rest run before the look.
    @Test(
      "After a resize, a growing dock and the plan appearing, layout comes to rest",
      arguments: [LayoutScrollBudget.Limits.none, LayoutScrollBudget.Limits(quiet: 0.1)])
    func layoutRests(limits: LayoutScrollBudget.Limits) async throws {
      let conversation = unevenSession(turns: 80)
      let pane = TranscriptPane(width: Self.wide, dock: 60)
      let window = try await shortPane(pane, conversation, limits: limits)
      defer { window.close() }
      let changes: [(name: String, change: () -> Void)] = [
        ("narrower", { pane.width = 420 }),
        ("dock grew", { pane.dock = 150 }),
        ("plan", { conversation.state.sections = [self.plan()] }),
        ("narrowest", { pane.width = 260 }),
        ("dock fills", { pane.dock = Self.height - 40 }),
        ("resized", { self.resize(pane, in: window) }),
      ]
      for (name, change) in changes {
        let before = HangTrace.tallies()
        change()
        try await letTasksRun(window, milliseconds: 300)
        let during = churn(since: before)
        let settled = HangTrace.tallies()
        for _ in 0..<20 { try await letTasksRun(window, milliseconds: 20) }
        let after = churn(since: settled)
        #expect(after.heights == 0 && after.scrolls == 0, "\(name): \(during), then \(after)")
      }
    }

    /// Measuring the distance moves the position, which is layout changing with nothing new;
    /// so each look comes once, after layout had time to rest and to forget the drag's heights.
    @Test("A reader at the end is still there after the window was dragged to many sizes")
    func resizeKeepsEnd() async throws {
      let conversation = unevenSession(turns: 80)
      let pane = TranscriptPane(width: Self.wide, dock: 60)
      let window = try await shortPane(pane, conversation)
      defer { window.close() }
      let viewport = TranscriptScrollDriver(screen: window)
      #expect(try await waitUntil(window) { viewport.distanceToEnd() < 2 })
      let before = HangTrace.tallies()
      resize(pane, in: window)
      pane.dock = 100
      try await letTasksRun(window, milliseconds: Int(FollowedHeights.memory * 1000) + 500)
      let dragged = churn(since: before)
      #expect(viewport.distanceToEnd() < 2, "\(dragged)")
      // A step of the drag takes at most one scroll for its width and one for its dock.
      #expect(dragged.scrolls <= 2 * Self.dragSteps)

      // New output is followed as before.
      try await letTasksRun(window, milliseconds: Int(FollowedHeights.memory * 1000) + 500)
      let late = HangTrace.tallies()
      conversation.append(TranscriptFixture.answer("late", "A late answer", responseID: "late"))
      #expect(try await waitUntil(window) { try window.shows("A late answer") })
      try await letTasksRun(window, milliseconds: 500)
      #expect(viewport.distanceToEnd() < 2, "\(churn(since: late))")
    }
  }
#endif
