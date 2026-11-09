#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Automations page, clicked", .serialized)
  @MainActor
  struct PagesAutomationListTests {
    private let log = ActionLog()

    private var actions: AutomationsActions {
      let log = log
      var actions = AutomationsActions()
      actions.filter = { log.record("filter \($0.rawValue) [\($1)]") }
      actions.create = { log.record("create \($0?.id ?? "blank")") }
      actions.createTrigger = { log.record("trigger \($0)") }
      actions.openDetail = { log.record("detail \($0)") }
      actions.edit = { log.record("edit \($0)") }
      actions.setPaused = { log.record("paused \($0) \($1)") }
      actions.runNow = { log.record("run \($0)") }
      actions.delete = { log.record("delete \($0)") }
      actions.openSession = { log.record("session \($0)") }
      actions.retry = { log.record("retry") }
      actions.dismissError = { log.record("dismiss") }
      return actions
    }

    private func row(
      _ id: String, paused: Bool = false, busy: Bool = false, lastRun: String? = nil
    ) -> AutomationRow {
      var row = AutomationRow(
        id: id, name: "Automation \(id)", scheduleText: "Every day at 9:00 AM",
        nextRunText: paused ? nil : "in 8 mins", isPaused: paused)
      row.isBusy = busy
      row.lastRunSessionID = lastRun
      return row
    }

    private func page(
      _ state: AutomationsViewState, actions: AutomationsActions? = nil
    ) -> OffscreenWindow<AutomationsView> {
      SystemSideEffects.reset()
      return OffscreenWindow(
        AutomationsView(state: state, actions: actions ?? self.actions), width: 1_000, height: 800)
    }

    private var chips: [AutomationTriggerChip] {
      [AutomationTriggerChip(id: "jira", title: "Jira tickets", systemImage: "ticket")]
    }

    @Test("the filter and search report both values as they change")
    func filterAndSearch() throws {
      let screen = page(AutomationsViewState(rows: [row("a")], hasAny: true))
      defer { screen.close() }
      let filter = try #require(screen.segmentedControls.first)
      try screen.click(segment: 1, of: filter)
      #expect(log.entries == ["filter active []"])
      try screen.click(segment: 2, of: filter)
      #expect(log.entries.last == "filter paused []")
      let search = try #require(screen.fields.first)
      try screen.replaceText(in: search, with: "br")
      #expect(log.entries.suffix(2) == ["filter paused [b]", "filter paused [br]"])
    }

    @Test("suggestions show under the All filter only, and go away for the others")
    func suggestionsFollowFilter() throws {
      let screen = page(AutomationsViewState(rows: [row("a")], hasAny: true))
      defer { screen.close() }
      #expect(try screen.shows("Suggestions"))
      let filter = try #require(screen.segmentedControls.first)
      try screen.click(segment: 1, of: filter)
      #expect(try !screen.shows("Suggestions"))
    }

    @Test("New automation offers a blank one, triggers and templates, each creating its own")
    func newMenu() throws {
      var state = AutomationsViewState(rows: [], hasAny: true)
      state.triggers = chips
      let screen = page(state)
      defer { screen.close() }
      let new = try #require(screen.popUps.first)
      #expect(new.title == "New automation")
      try screen.choose("Create manually", inPopUp: new)
      try screen.choose("Jira tickets", inPopUp: new)
      try screen.choose("PR sweep", inPopUp: new)
      #expect(log.entries == ["create blank", "trigger jira", "create pr-sweep"])
    }

    @Test("a server with no triggers offers no trigger section")
    func newMenuWithoutTriggers() throws {
      let screen = page(AutomationsViewState(rows: [], hasAny: true))
      defer { screen.close() }
      let titles = try screen.titles(inPopUp: try #require(screen.popUps.first))
      #expect(!titles.contains("When something happens"))
      #expect(titles.contains("From a template"))
    }

    @Test("without a create action there is nothing to create from")
    func noCreate() throws {
      var actions = actions
      actions.create = nil
      let screen = page(AutomationsViewState(rows: [], hasAny: false), actions: actions)
      defer { screen.close() }
      #expect(screen.popUps.isEmpty)
      #expect(screen.controlFrames.count == 1, "only the search field")
      #expect(try screen.shows("No automations yet"))
    }

    @Test("each suggestion button creates from that suggestion")
    func suggestionButtons() throws {
      var state = AutomationsViewState(rows: [], hasAny: false)
      state.triggers = chips
      let screen = page(state)
      defer { screen.close() }
      // New automation, search, then the trigger chip and the three suggestions.
      let buttons = screen.controlFrames.dropFirst(2)
      #expect(buttons.count == 4)
      for frame in buttons { try screen.click(CGPoint(x: frame.midX, y: frame.midY)) }
      #expect(
        log.entries == [
          "trigger jira", "create follow-up-monitor", "create pr-sweep", "create news-digest",
        ])
    }

    @Test("a row's menu runs, edits, pauses and opens the last run of that row")
    func rowMenu() throws {
      let screen = page(
        AutomationsViewState(rows: [row("a", lastRun: "s1"), row("b", paused: true)], hasAny: true))
      defer { screen.close() }
      #expect(try screen.shows("Every day at 9:00 AM \u{00B7} Next run in 8 mins"))
      #expect(try screen.shows("Paused"))
      let menus = screen.popUps.dropFirst()
      let first = try #require(menus.first)
      let second = try #require(menus.last)
      #expect(try screen.titles(inPopUp: second).contains("Resume"))
      #expect(try !screen.titles(inPopUp: second).contains("Open last run"))
      for title in ["Run now", "Edit", "Pause", "Open last run"] {
        try screen.choose(title, inPopUp: first)
      }
      try screen.choose("Resume", inPopUp: second)
      #expect(log.entries == ["run a", "edit a", "paused a true", "session s1", "paused b false"])
    }

    @Test("Delete asks first, and says nothing was deleted until the answer is yes")
    func deleteConfirms() throws {
      let screen = page(AutomationsViewState(rows: [row("a")], hasAny: true))
      defer { screen.close() }
      let menu = try #require(screen.popUps.last)
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      try screen.choose("Delete", inPopUp: menu)
      #expect(SystemSideEffects.record.alertMessages == ["Delete this automation?"])
      #expect(log.entries.isEmpty)
      SystemSideEffects.answer(alert: .alertFirstButtonReturn)
      try screen.choose("Delete", inPopUp: menu)
      #expect(log.entries == ["delete a"])
    }

    @Test(
      "a right click on a row offers its menu's actions, and nothing while a write is in flight")
    func contextMenu() throws {
      func rowScreen(busy: Bool) -> OffscreenWindow<AutomationRowView> {
        var actions = AutomationRowView.Actions()
        let log = log
        actions.runNow = { log.record("run") }
        actions.edit = { log.record("edit") }
        return OffscreenWindow(
          AutomationRowView(row: row("a", busy: busy), actions: actions), width: 600, height: 120)
      }
      SystemSideEffects.reset()
      let idle = rowScreen(busy: false)
      defer { idle.close() }
      let center = CGPoint(x: 200, y: 60)
      let menu = try #require(try idle.contextMenu(at: center))
      #expect(menu.items.map(\.title) == ["Run now", "Edit"])
      try idle.choose("Edit", in: menu)
      #expect(log.entries == ["edit"])

      let busy = rowScreen(busy: true)
      defer { busy.close() }
      #expect(try busy.contextMenu(at: center)?.items.isEmpty ?? true)
      let button = try #require(busy.popUps.last)
      #expect(!button.isEnabled)
    }

    @Test("a failed load offers Retry; a failed action offers Dismiss")
    func errors() throws {
      let screen = page(
        AutomationsViewState(
          rows: [], hasAny: true, loadError: "Server down", actionError: "Can't pause"))
      defer { screen.close() }
      #expect(try screen.shows("Couldn\u{2019}t load automations."))
      #expect(try screen.shows("Server down"))
      #expect(try screen.shows("Can't pause"))
      // New automation, search, filter, Dismiss, Retry.
      try screen.clickControl(at: 3)
      #expect(log.entries == ["dismiss"])
      try screen.clickControl(at: 4)
      #expect(log.entries == ["dismiss", "retry"])
    }

    @Test("loading, no matches and no automations at all each say so")
    func emptyStates() throws {
      let cases: [(AutomationsViewState, String)] = [
        (AutomationsViewState(rows: [], hasAny: false, isLoading: true), "Loading automations"),
        (AutomationsViewState(rows: [], hasAny: true), "No automations found"),
        (AutomationsViewState(rows: [], hasAny: false), "No automations yet"),
      ]
      for (state, text) in cases {
        let screen = page(state)
        defer { screen.close() }
        #expect(try screen.shows(text), "\(text)")
      }
    }

    @Test("nothing to filter when there are no automations at all")
    func noFilterWhenEmpty() {
      let screen = page(AutomationsViewState(rows: [], hasAny: false))
      defer { screen.close() }
      #expect(screen.segmentedControls.isEmpty)
    }

    @Test("every button stays in the window at a narrow width, even with a long name")
    func narrowWidth() {
      SystemSideEffects.reset()
      var state = AutomationsViewState(
        rows: [row("a")], hasAny: true)
      state.rows[0].name = String(repeating: "Long automation name ", count: 12)
      state.triggers = chips
      let screen = OffscreenWindow(
        AutomationsView(state: state, actions: actions), width: 520, height: 800)
      defer { screen.close() }
      for frame in screen.controlFrames {
        #expect(frame.minX >= 0 && frame.maxX <= 520, "\(frame)")
      }
    }
  }
#endif
