#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Worked folds, diffs and sub-agent groups", .serialized)
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

    private func group(
      _ children: [EventSection], actions: ConversationActions
    ) -> OffscreenWindow<AnyView> {
      var state = ConversationViewState(header: TranscriptFixture.header)
      state.sections = children
      return transcriptScreen(SubagentGroupView(state: state, actions: actions))
    }

    private func child(_ id: String, _ status: SubagentStatus, error: String? = nil) -> EventSection
    {
      PreviewData.childSection(id, title: "Child \(id)", state: status, error: error)
    }

    private var openingActions: ConversationActions {
      var actions = ConversationActions()
      let log = self.log
      actions.openChild = { log.add("open \($0)") }
      return actions
    }

    @Test("The header opens and folds the group; a row opens its child")
    func groupOpens() throws {
      let screen = group([child("a", .running)], actions: openingActions)
      defer { screen.close() }
      let wasOpen = try screen.shows("Child a")
      try screen.clickControl(at: 0)
      #expect(try screen.shows("Child a") != wasOpen)
      if wasOpen { try screen.clickControl(at: 0) }
      #expect(try screen.shows("Child a"))
      try screen.clickControl(at: 1)
      #expect(log.entries == ["open a"])
    }

    @Test("Finished children fold behind a count while others run")
    func doneFolds() throws {
      let screen = group([child("a", .running), child("b", .ready)], actions: openingActions)
      defer { screen.close() }
      if try !screen.shows("Child a") { try screen.clickControl(at: 0) }
      #expect(try screen.shows("1 done"))
      #expect(try !screen.shows("Child b"))
      let done = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: done.midX, y: done.midY))
      #expect(try screen.shows("Child b"))
      #expect(try screen.shows("Hide 1 done"))
    }

    @Test("With nothing running, the finished children show directly")
    func allDone() throws {
      let screen = group([child("b", .ready)], actions: openingActions)
      defer { screen.close() }
      if try !screen.shows("Child b") { try screen.clickControl(at: 0) }
      #expect(try screen.shows("Child b"))
      #expect(try !screen.shows("1 done"))
    }

    @Test("A failed child says why, in chat and in the CLI's line")
    func failedChild() throws {
      let screen = group([child("a", .failed, error: "It broke")], actions: openingActions)
      defer { screen.close() }
      if try !screen.shows("It broke") { try screen.clickControl(at: 0) }
      #expect(try screen.shows("It broke"))

      var state = ConversationViewState(header: TranscriptFixture.header)
      state.sections = [
        PreviewData.childSection("a", title: "Child a", state: .failed, error: "It broke")
      ]
      let cli = transcriptScreen(CLISubagentLines(state: state, actions: ConversationActions()))
      defer { cli.close() }
      #expect(try cli.shows("It broke"))
    }
  }
#endif
