#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Automation page, clicked", .serialized)
  @MainActor
  struct PagesAutomationDetailTests {
    private let log = ActionLog()

    private var actions: AutomationDetailActions {
      let log = log
      var actions = AutomationDetailActions()
      actions.back = { log.record("back") }
      actions.edit = { log.record("edit") }
      actions.delete = { log.record("delete") }
      actions.runNow = { log.record("run") }
      actions.setPaused = { log.record("paused \($0)") }
      actions.openSession = { log.record("session \($0)") }
      actions.retry = { log.record("retry") }
      actions.dismissError = { log.record("dismiss") }
      return actions
    }

    private func state(paused: Bool = false, name: String = "Brief") -> AutomationDetailState {
      AutomationDetailState(
        id: "a", name: name, isPaused: paused, scheduleText: "Every day at 9:00 AM",
        prompt: "Summarize", agent: "Claude Code", host: "Build Mac")
    }

    private func page(
      _ state: AutomationDetailState, actions: AutomationDetailActions? = nil, width: CGFloat = 800
    ) -> OffscreenWindow<AutomationDetailView> {
      SystemSideEffects.reset()
      return OffscreenWindow(
        AutomationDetailView(state: state, actions: actions ?? self.actions), width: width,
        height: 700)
    }

    @Test("back, edit and run now each do their own thing")
    func headerButtons() throws {
      let screen = page(state())
      defer { screen.close() }
      try screen.clickControl(at: 0)
      #expect(log.entries == ["back"])
      try screen.clickControl(at: 1)
      #expect(log.entries == ["back", "edit"])
      try screen.clickControl(at: 3)
      #expect(log.entries == ["back", "edit", "run"])
    }

    @Test("Delete asks first; only yes deletes")
    func delete() throws {
      let screen = page(state())
      defer { screen.close() }
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      try screen.clickControl(at: 2)
      #expect(SystemSideEffects.record.alertMessages == ["Delete this automation?"])
      #expect(log.entries.isEmpty)
      SystemSideEffects.answer(alert: .alertFirstButtonReturn)
      try screen.clickControl(at: 2)
      #expect(log.entries == ["delete"])
    }

    @Test("the switch pauses an active automation and resumes a paused one")
    func activeSwitch() throws {
      let active = page(state())
      defer { active.close() }
      #expect(try active.shows("Active"))
      try active.click(try #require(active.switches.first))
      #expect(log.entries == ["paused true"])

      let paused = page(state(paused: true))
      defer { paused.close() }
      #expect(try paused.shows("Paused"))
      try paused.click(try #require(paused.switches.first))
      #expect(log.entries == ["paused true", "paused false"])
    }

    @Test("while a write is in flight, nothing can start another")
    func busy() throws {
      let idle = page(state())
      let buttons = Array(idle.controlFrames[1...3])
      let switchView = try #require(idle.switches.first)
      let toggle = switchView.convert(switchView.bounds, to: idle.host)
      idle.close()
      var busy = state()
      busy.isBusy = true
      let screen = page(busy)
      defer { screen.close() }
      #expect(try screen.shows("In progress"))
      #expect(try !screen.shows("Run now"))
      for frame in buttons { try screen.click(CGPoint(x: frame.midX, y: frame.midY)) }
      try screen.click(CGPoint(x: toggle.midX, y: toggle.midY))
      #expect(log.entries.isEmpty)
      #expect(SystemSideEffects.record.alertMessages.isEmpty)
    }

    @Test("without actions the page is read only")
    func readOnly() throws {
      let screen = page(state(), actions: AutomationDetailActions())
      defer { screen.close() }
      #expect(screen.switches.isEmpty)
      #expect(try screen.shows("Summarize"))
      #expect(try screen.shows("Build Mac"))
      #expect(try screen.shows("No runs yet."))
      #expect(screen.controlFrames.isEmpty)
    }

    @Test("a failed action can be dismissed, and failed runs retried")
    func errors() throws {
      var failed = state()
      failed.actionError = "Can't pause"
      failed.runsError = "Server down"
      let screen = page(
        failed,
        actions: {
          var actions = actions
          actions.back = nil
          actions.edit = nil
          actions.delete = nil
          actions.runNow = nil
          actions.setPaused = nil
          return actions
        }())
      defer { screen.close() }
      #expect(try screen.shows("Can't pause"))
      #expect(try screen.shows("Couldn\u{2019}t load run history."))
      try screen.clickControl(at: 0)
      #expect(log.entries == ["dismiss"])
      try screen.clickControl(at: 1)
      #expect(log.entries == ["dismiss", "retry"])
    }

    @Test("loading runs says so")
    func loadingRuns() throws {
      var loading = state()
      loading.isLoadingRuns = true
      let screen = page(loading)
      defer { screen.close() }
      #expect(try screen.shows("Loading runs"))
      #expect(try !screen.shows("No runs yet."))
    }

    @Test("a run with a session opens it; one without has nothing to click")
    func runRows() throws {
      var opened = AutomationRunRow(id: "1", indicator: .completed, timestamp: "Today, 8:00 AM")
      opened.sessionID = "s1"
      opened.duration = "1m 42s"
      var failed = AutomationRunRow(id: "2", indicator: .failed, timestamp: "Today, 7:00 AM")
      failed.failureStage = "Host"
      failed.failureReason = "The host was offline."
      var withState = state()
      withState.runs = [opened, failed]
      let screen = page(
        withState,
        actions: {
          var actions = AutomationDetailActions()
          let log = log
          actions.openSession = { log.record("session \($0)") }
          return actions
        }())
      defer { screen.close() }
      #expect(try screen.shows("1m 42s"))
      #expect(try screen.shows("Host \u{00B7} The host was offline."))
      #expect(screen.controlFrames.count == 1, "only the run with a session is a button")
      try screen.clickControl(at: 0)
      #expect(log.entries == ["session s1"])
    }

    @Test(
      "every run state draws its status",
      arguments: [
        AutomationRunRow.Indicator.failed, .skipped, .inFlight, .unread, .completed, .queued,
      ])
    func indicators(indicator: AutomationRunRow.Indicator) throws {
      var run = AutomationRunRow(id: "1", indicator: indicator, timestamp: "Today, 8:00 AM")
      run.statusLabel = "Queued"
      SystemSideEffects.reset()
      let screen = OffscreenWindow(
        AutomationRunRowView(run: run, open: nil), width: 400, height: 80)
      defer { screen.close() }
      #expect(try screen.shows("Today, 8:00 AM"))
      #expect(try screen.shows("Queued"))
    }

    @Test(
      "the header's buttons stay in the window at a narrow width, however long the name",
      arguments: [
        "Brief", String(repeating: "Long automation name ", count: 10),
        String(repeating: "Unbroken", count: 30),
      ])
    func narrowHeader(name: String) throws {
      let width: CGFloat = 320
      let screen = page(state(name: name), width: width)
      defer { screen.close() }
      #expect(screen.controlFrames.count >= 4)
      for frame in screen.controlFrames {
        #expect(frame.minX >= 0 && frame.maxX <= width, "\(frame)")
      }
    }
  }
#endif
