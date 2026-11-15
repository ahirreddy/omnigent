#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Whether the turn is still on a fold's steps.
  @MainActor @Observable
  private final class FoldTurn {
    var isLive = true
  }

  /// The sizes two reveals took.
  @MainActor
  private final class RevealedSizes {
    var half: CGSize?
    var empty: CGSize?
  }

  private struct FoldHost: View {
    let turn: FoldTurn
    let item: TranscriptItem

    var body: some View {
      WorkedFold(items: [item], isLive: turn.isLive, duration: nil, decorations: [:])
    }
  }

  @Suite("Worked folds, diffs and sub-agents", .serialized)
  @MainActor
  struct TranscriptStepsAndGroupsTests {
    private let log = HostLog()

    init() {
      SystemSideEffects.reset()
    }

    // MARK: Worked folds

    @Test("Clicking a settled turn's Worked header opens its steps, and again folds them")
    func workedFold() throws {
      let item = TranscriptItem.activity(TranscriptFixture.activityRow(.error, title: "A step"))
      let screen = transcriptScreen(
        WorkedFold(items: [item], isLive: false, duration: 12, decorations: [:]))
      defer { screen.close() }
      #expect(try !screen.shows("A step"))
      try screen.clickControl(at: 0)
      #expect(try screen.shows("A step"))
      try screen.clickControl(at: 0)
      #expect(try !screen.shows("A step"))
    }

    @Test("Steps the turn has finished close by themselves; ones the reader opened stay open")
    func foldFollowsTheTurnUnlessTheReaderChose() async throws {
      let item = TranscriptItem.activity(TranscriptFixture.activityRow(.error, title: "A step"))
      let turn = FoldTurn()
      let screen = transcriptScreen(FoldHost(turn: turn, item: item))
      defer { screen.close() }
      #expect(try screen.shows("A step"), "open while the turn is on these steps")

      turn.isLive = false
      #expect(try await waitUntil(screen) { try !screen.shows("A step") }, "closed once done")

      try screen.clickControl(at: 0)
      #expect(try await waitUntil(screen) { try screen.shows("A step") })
      turn.isLive = true
      turn.isLive = false
      try await letTasksRun(screen, milliseconds: 400)
      #expect(try screen.shows("A step"), "the reader's choice outlasts the turn's")
    }

    @Test("A reveal shows its content by height, a part at a time")
    func revealLayout() {
      var layout = RevealLayout(progress: 0.25)
      #expect(layout.animatableData == 0.25)
      layout.animatableData = 0.5
      let sizes = RevealedSizes()
      let screen = OffscreenWindow(
        VStack {
          layout { Color.clear.frame(width: 100, height: 80) }
            .onGeometryChange(for: CGSize.self) {
              $0.size
            } action: {
              sizes.half = $0
            }
          RevealLayout(progress: 1) {}
            .onGeometryChange(for: CGSize.self) {
              $0.size
            } action: {
              sizes.empty = $0
            }
        }, width: 200, height: 200)
      defer { screen.close() }
      screen.settle()
      #expect(sizes.half == CGSize(width: 100, height: 40))
      #expect(sizes.empty == .zero)
    }

    // MARK: Diffs

    private func longDiff(_ count: Int) -> DiffSummary {
      DiffSummary(
        files: ["a.swift"], added: count, removed: 0,
        lines: (0..<count).map { DiffSummary.Line(kind: .added, text: "+line \($0)") })
    }

    @Test("A long diff stops at the limit and says how much is left, or offers the rest")
    func longDiffFolds() throws {
      let named = transcriptScreen(DiffView(diff: longDiff(5), maxLines: 2))
      defer { named.close() }
      #expect(try named.shows("3 more lines"))
      #expect(try !named.shows("+line 2"))

      let log = self.log
      let offered = transcriptScreen(
        DiffView(diff: longDiff(5), maxLines: 2, showAll: { log.add("show all") }))
      defer { offered.close() }
      let button = try #require(offered.controlFrames.last)
      try offered.click(CGPoint(x: button.midX, y: button.midY))
      #expect(log.entries == ["show all"])

      let wrapped = transcriptScreen(DiffView(diff: longDiff(1), wrapsLines: true))
      defer { wrapped.close() }
      #expect(try wrapped.shows("+line 0"))
    }

    @Test("A write's arguments show as the file's diff instead of raw arguments")
    func editDiffStandsIn() throws {
      let arguments = #"{"file_path":"a.txt","content":"hello"}"#
      let call = TranscriptFixture.toolCall(
        "call", title: "Write",
        details: [DetailSection(id: "arguments", title: "Arguments", text: arguments, isCode: true)]
      )
      let result = TranscriptFixture.toolResult(
        "result", callID: "call", output: #"{"created": true}"#)
      let screen = transcriptScreen(ToolRowView(entry: ToolEntry(call: call, result: result)))
      defer { screen.close() }
      try screen.clickControl(at: 0)
      #expect(try screen.shows("+hello"))
      #expect(try !screen.shows("Arguments"))
    }

    @Test("The step's context menu copies its input and output")
    func toolContextMenu() throws {
      let entry = ToolEntry(
        call: TranscriptFixture.toolCall("call", summary: "ls -la"),
        result: TranscriptFixture.toolResult("result", callID: "call", output: "total 0"))
      let screen = transcriptScreen(ToolRowView(entry: entry))
      defer { screen.close() }
      let menu = try #require(try screen.firstContextMenu())
      try screen.choose("Copy Input", in: menu)
      #expect(copiedText() == "ls -la")
      let again = try #require(try screen.firstContextMenu())
      try screen.choose("Copy Output", in: again)
      #expect(copiedText() == "total 0")
    }

    @Test("A cancelled step isn't drawn as finished")
    func cancelledStep() throws {
      let screen = transcriptScreen(
        ActivityStatusView(isRunning: false, isFailure: false, status: "Cancelled"))
      defer { screen.close() }
      #expect(screen.controlFrames.isEmpty)
    }

    // MARK: Sub-agents

    @Test("A sub-agent's request shows inline with the parent's own")
    func subagentRequestInline() throws {
      let state = PreviewData.subagentConversation
      let screen = transcriptScreen(
        TranscriptView(state: state, actions: ConversationActions(respond: { _, _ in })),
        height: 900)
      defer { screen.close() }
      screen.settle(0.3)
      #expect(try screen.shows("migrate --check"), "the blocked child's request")
    }
  }
#endif
