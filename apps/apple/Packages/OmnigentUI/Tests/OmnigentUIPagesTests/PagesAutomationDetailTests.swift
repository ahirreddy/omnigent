#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

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
      #expect(try !screen.shows("Build Mac"), "the configuration starts folded, as the web's")
      try screen.clickElement("automation-detail-configuration")
      #expect(try screen.shows("Build Mac"))
      #expect(try screen.shows("No runs yet."))
      #expect(screen.controlFrames.count == 1, "only the Configuration disclosure")
    }

    @Test("a shared automation names its owner and shows every action disabled")
    func sharedWithMe() throws {
      var shared = state()
      shared.sharedBy = "Ana"
      shared.startsFrom = "Each run starts with a copy of a session the owner chose."
      shared.promptTitle = "Additional instructions"
      let screen = page(shared)
      defer { screen.close() }
      #expect(try screen.shows("Shared by Ana"))
      #expect(try screen.shows("Each run starts with a copy of a session the owner chose."))
      #expect(try screen.shows("Additional instructions"))
      #expect(try screen.shows("Run now"), "shown, but disabled")
      // Share, Edit, Delete, Run now and the switch are disabled; only Back acts.
      for frame in screen.controlFrames { try screen.click(CGPoint(x: frame.midX, y: frame.midY)) }
      try screen.click(try #require(screen.switches.first))
      #expect(log.entries == ["back"], "\(log.entries)")
      #expect(SystemSideEffects.record.alertMessages.isEmpty)
    }

    @Test("a trigger runs when items match and has no Run now; its settings are listed")
    func triggerAndConfiguration() throws {
      var trigger = state()
      trigger.isTrigger = true
      trigger.scheduleText = "Runs when new items match"
      trigger.promptTitle = "Instructions"
      trigger.configuration = [
        AutomationConfigField(label: "Model", value: "Agent default"),
        AutomationConfigField(label: "Cost limit per run", value: "$5.00"),
      ]
      trigger.configurationNote = "The continued session may have changed settings."
      let screen = page(trigger)
      defer { screen.close() }
      #expect(try screen.shows("Runs when new items match"))
      #expect(try screen.shows("Instructions"))
      #expect(try !screen.shows("Run now"))
      try screen.clickElement("automation-detail-configuration")
      #expect(try screen.shows("Cost limit per run"))
      #expect(try screen.shows("$5.00"))
      #expect(try screen.shows("The continued session may have changed settings."))
    }

  }

  extension PagesAutomationDetailTests {
    @Test("a run shows its cost, what it waits on, the server's detail and its PRs")
    func runDetails() throws {
      var run = AutomationRunRow(id: "1", indicator: .failed, timestamp: "Today, 8:00 AM")
      run.sessionID = "s1"
      run.sessionCost = "Session cost $1.23"
      run.needsApproval = true
      run.statusLabel = "Running"
      run.failureStage = "Sandbox"
      run.failureReason = "Couldn't create the sandbox."
      run.errorDetail = "Quota exceeded. Retry later."
      run.pullRequestSummary = "PR #7 merged"
      run.pullRequests = [
        AutomationRunPullRequest(
          url: try #require(URL(string: "https://git.example.com/acme/app/pull/7")), number: "#7",
          title: "Fix", status: "Merged", repository: "acme/app", origin: "Opened by this run")
      ]
      var withRun = state()
      withRun.runs = [run]
      var actions = actions
      let log = log
      actions.openPullRequest = { log.record("pr \($0.absoluteString)") }
      let screen = page(withRun, actions: actions)
      defer { screen.close() }
      #expect(try screen.shows("Session cost $1.23"))
      #expect(try screen.shows("Session needs approval \u{00B7} Open to review"))
      #expect(try !screen.shows("Running"), "a run waiting on approval says that instead")
      #expect(try screen.shows("Quota exceeded. Retry later."))
      #expect(try screen.shows("PR #7 merged"))
      #expect(
        try screen.shows(
          "Session cost is each session\u{2019}s current recorded total. Runs sharing a session show the same total. Separate sub-agent sessions are excluded."
        ))
      let menu = try #require(screen.popUps.last)
      try screen.choose("#7 Fix", inPopUp: menu)
      #expect(log.entries == ["pr https://git.example.com/acme/app/pull/7"])
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
      // Dismiss, the Configuration disclosure, then Retry.
      try screen.clickControl(at: 0)
      #expect(log.entries == ["dismiss"])
      try screen.clickControl(at: 2)
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
      #expect(
        screen.controlFrames.count == 2,
        "the Configuration disclosure, and only the run with a session is a button")
      try screen.clickControl(at: 1)
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

    @Test("the page reads as the web's: back, title with its actions, status, prompt, runs")
    func layout() throws {
      var detail = state()
      detail.canShare = true
      var actions = actions
      actions.share = {}
      var run = AutomationRunRow(id: "1", indicator: .completed, timestamp: "Today, 8:00 AM")
      run.sessionID = "s1"
      detail.runs = [run]
      let screen = page(detail, actions: actions)
      defer { screen.close() }
      let identifiers = [
        "automation-detail-back", "automation-detail-title", "automation-detail-share",
        "automation-detail-edit", "automation-detail-delete", "automation-detail-run-now",
        "automation-detail-active", "automation-detail-state", "automation-detail-schedule",
        "automation-detail-prompt", "automation-detail-configuration", "automation-detail-runs",
      ]
      let frames = try screen.withAccessibilityTree {
        try identifiers.reduce(into: [String: CGRect]()) {
          $0[$1] = try screen.accessibilityFrame($1)
        }
      }
      func frame(_ id: String) throws -> CGRect { try #require(frames[id]) }
      let back = try frame("automation-detail-back")
      let title = try frame("automation-detail-title")
      #expect(back.maxY <= title.minY, "the way back leads")
      let actionsInOrder = try [
        "automation-detail-share", "automation-detail-edit", "automation-detail-delete",
        "automation-detail-run-now",
      ].map(frame)
      for (leading, trailing) in zip(actionsInOrder, actionsInOrder.dropFirst()) {
        #expect(leading.maxX <= trailing.minX, "Share, Edit, Delete, then Run now")
      }
      let runNow = try frame("automation-detail-run-now")
      #expect(runNow.maxX > 600, "the actions sit at the right")
      let toggle = try frame("automation-detail-active")
      let pill = try frame("automation-detail-state")
      let schedule = try frame("automation-detail-schedule")
      #expect(title.maxY <= toggle.minY)
      #expect(toggle.maxX <= pill.minX && pill.maxX <= schedule.minX, "switch, pill, schedule")
      #expect(abs(toggle.midY - schedule.midY) < 4)
      let prompt = try frame("automation-detail-prompt")
      let configuration = try frame("automation-detail-configuration")
      #expect(schedule.maxY <= prompt.minY && prompt.maxY <= configuration.minY)
      #expect(try !screen.shows("AGENT"), "the configuration starts folded")
      let runRow = try frame("automation-detail-runs")
      #expect(configuration.maxY + 24 <= runRow.minY)
    }
  }
#endif
