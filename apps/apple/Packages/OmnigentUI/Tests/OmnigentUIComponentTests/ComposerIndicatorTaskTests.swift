#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The row's task indicators, pull request, context line and liveness, and the pickers a
  /// command opens.
  @Suite("Composer: indicators, context line and pickers", .serialized)
  @MainActor
  struct ComposerIndicatorTaskTests {
    private let log = ComposerActionLog()

    private func tray(_ tray: ComposerTray) -> OffscreenWindow<ComposerScreen> {
      openComposer(ComposerScreenModel(state: ComposerViewState(tray: tray)), log.actions)
    }

    private func child(_ id: String, _ status: SubagentStatus) -> SubagentChild {
      SubagentChild(id: id, title: "Agent \(id)", status: status)
    }

    @Test("the sub-agent menu opens each child, from anywhere on the chip")
    func subagents() throws {
      var tray = ComposerTray()
      tray.indicators = ComposerTaskIndicators(subagents: [
        child("a", .running), child("b", .needsYou),
      ])
      let screen = self.tray(tray)
      defer { screen.close() }
      let menu = try screen.chip(0)
      try screen.choose("Agent b", in: menu)
      #expect(log.events == ["subagent:b"])
    }

    @Test("the goal pill opens the goal, with a pause glyph when it can resume")
    func goal() throws {
      for canResume in [false, true] {
        log.events = []
        var tray = ComposerTray()
        tray.indicators = ComposerTaskIndicators(
          goal: ComposerGoal(objective: "Ship it", status: "active", canResume: canResume))
        let screen = self.tray(tray)
        defer { screen.close() }
        #expect(try screen.shows("Ship it"))
        let pill = try #require(screen.chips.first)
        try screen.click(screen.clickPoint(pill))
        #expect(log.events == ["openGoal"])
      }
    }

    @Test("the background-task count opens its list, and an emptied list closes it")
    func backgroundTasks() throws {
      var tray = ComposerTray()
      tray.indicators = ComposerTaskIndicators(
        backgroundTasks: 2,
        backgroundTaskList: [
          ComposerBackgroundTask(id: "1", title: "Server", command: "npm run dev"),
          ComposerBackgroundTask(id: "2", title: "Watcher"),
        ], backgroundTaskNote: "Stop them from the terminal.")
      let model = ComposerScreenModel(state: ComposerViewState(tray: tray))
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      #expect(try screen.shows("2"))
      let count = try #require(screen.chips.first)
      try screen.click(screen.clickPoint(count))
      screen.settle(0.3)
      #expect(screen.popoverWindow != nil)
      model.state.tray?.indicators.backgroundTasks = 0
      screen.settle(0.3)
      #expect(screen.popoverWindow == nil)
    }

    @Test("the pull request chip opens the tab; without a handler it can't be pressed")
    func pullRequestChip() throws {
      var tray = ComposerTray(pullRequest: "#2041")
      tray.pullRequestStatus = .open
      let screen = self.tray(tray)
      defer { screen.close() }
      #expect(try screen.shows("#2041"))
      let chip = try #require(screen.chips.first)
      try screen.click(screen.clickPoint(chip))
      #expect(log.events == ["pullRequests"])

      var actions = log.actions
      actions.extras.indicators.openPullRequests = nil
      let other = openComposer(
        ComposerScreenModel(state: ComposerViewState(tray: ComposerTray(pullRequest: "#1"))),
        actions)
      defer { other.close() }
      #expect(other.chips.isEmpty)
    }

    @Test("the pull request preview lists each one's repository, number, status and title")
    func pullRequestPreview() throws {
      let request = PullRequestSummary(
        id: "1", number: 12, title: "Fix the thing", repo: "omnigent", url: "https://x",
        status: .open,
        detail: "")
      let screen = OffscreenWindow(ComposerPullRequestPreview(pullRequests: [request]))
      defer { screen.close() }
      #expect(try screen.shows("omnigent #12"))
      #expect(try screen.shows("Fix the thing"))
    }

    @Test("resting on the pull request chip shows the preview; passing over it doesn't")
    func pullRequestHover() async throws {
      var tray = ComposerTray(pullRequest: "#12")
      tray.pullRequestPreview = [
        PullRequestSummary(
          id: "1", number: 12, title: "Fix the thing", repo: "omnigent", url: "https://x",
          status: .open)
      ]
      let screen = self.tray(tray)
      defer { screen.close() }
      let chip = try #require(screen.chips.first)

      try screen.hover(screen.clickPoint(chip))
      try screen.endHover()
      screen.settle(0.45)
      await screen.drainTasks()
      #expect(screen.popoverWindow == nil)

      try screen.hover(screen.clickPoint(chip))
      #expect(screen.popoverWindow == nil)
      screen.settle(0.45)
      await screen.drainTasks()
      #expect(screen.popoverWindow != nil)
      try screen.endHover()
      screen.settle(0.3)
      #expect(screen.popoverWindow == nil)
    }

    @Test("the context line says where it runs and opens the details")
    func contextLine() throws {
      let state = ComposerViewState(context: ComposerSamples.context)
      let screen = openComposer(ComposerScreenModel(state: state), log.actions)
      defer { screen.close() }
      #expect(try screen.shows("Codex"))
      let row = try #require(screen.chips.first)
      try screen.click(screen.clickPoint(row))
      screen.settle(0.3)
      #expect(screen.popoverWindow != nil)
    }

    @Test("the context details name every part and say what wasn't reported")
    func contextDetails() throws {
      let full = OffscreenWindow(ExecutionContextDetails(context: ComposerSamples.context))
      defer { full.close() }
      #expect(try full.shows("Mac Studio \u{00B7} online"))
      #expect(try full.shows("/Users/ahir/src/omnigent"))
      #expect(try full.shows("auth-refresh"))

      var offline = ComposerSamples.context
      offline.isHostOnline = false
      offline.unavailableReason = "Connect this host."
      offline.branch = nil
      let warned = OffscreenWindow(ExecutionContextDetails(context: offline))
      defer { warned.close() }
      #expect(try warned.shows("Connect this host."))
      #expect(try warned.shows("Mac Studio \u{00B7} offline"))
      #expect(try warned.shows("Not reported"))

      var unknown = ComposerSamples.context
      unknown.isHostOnline = nil
      let plain = OffscreenWindow(ExecutionContextDetails(context: unknown))
      defer { plain.close() }
      #expect(try plain.shows("Mac Studio"))
    }

    // MARK: Pickers a command opens

    @Test("/permissions asks in a dialog and switches to the answer")
    func approvalPicker() throws {
      SystemSideEffects.reset()
      defer { SystemSideEffects.reset() }
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      let model = ComposerScreenModel(
        state: ComposerViewState(approvalModes: ComposerSamples.codexModes()))
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      model.state.approvalPickerRequest += 1
      screen.settle(0.5)
      #expect(SystemSideEffects.record.alertMessages == ["Codex approvals"])
      #expect(log.events == ["mode:approve-for-me"])
    }

    @Test("Choose Model asks in a dialog and takes the default or a model")
    func modelPicker() throws {
      SystemSideEffects.reset()
      defer { SystemSideEffects.reset() }
      let model = ComposerScreenModel(
        state: ComposerViewState(configuration: ComposerSamples.codexConfiguration))
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      model.state.modelPickerRequest += 1
      screen.settle(0.5)
      #expect(SystemSideEffects.record.alertMessages == ["Model"])
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      model.state.modelPickerRequest += 1
      screen.settle(0.5)
      #expect(log.events == ["model:default", "model:gpt-5.2-codex"])
    }

    @Test("a picker request with nothing to pick asks nothing")
    func pickerWithoutChoices() throws {
      SystemSideEffects.reset()
      let model = ComposerScreenModel(state: ComposerViewState())
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      model.state.approvalPickerRequest += 1
      model.state.modelPickerRequest += 1
      screen.settle(0.3)
      #expect(SystemSideEffects.record.alertMessages.isEmpty)
    }
  }
#endif
