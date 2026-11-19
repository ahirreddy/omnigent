#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  @Suite("Automations page, clicked", .serialized)
  @MainActor
  struct PagesAutomationListTests {
    private let log = ActionLog()

    private var actions: AutomationsActions {
      let log = log
      var actions = AutomationsActions()
      actions.filter = { log.record("filter \($0.rawValue) [\($1)]") }
      actions.create = { log.record("create blank") }
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

    private var cards: [AutomationTemplateCard] {
      [
        AutomationTemplateCard(
          id: "jira", title: "Jira tickets", description: "Watch for matching tickets.",
          requirement: "Requires a Jira MCP server.", systemImage: "ticket"),
        AutomationTemplateCard(
          id: "linear", title: "Linear issues", description: "Watch teams.",
          requirement: "Requires a Linear MCP server.", systemImage: "line.3.horizontal"),
      ]
    }

    /// Clicks one of the All / Active / Paused pills.
    private func pick<Content>(_ filter: AutomationsFilter, _ screen: OffscreenWindow<Content>)
      throws
    {
      try screen.clickElement("automations-filter-\(filter.rawValue)")
    }

    @Test("the filter and search report both values as they change")
    func filterAndSearch() throws {
      let screen = page(AutomationsViewState(rows: [row("a")], hasAny: true))
      defer { screen.close() }
      try pick(.active, screen)
      #expect(log.entries == ["filter active []"])
      try pick(.paused, screen)
      #expect(log.entries.last == "filter paused []")
      let search = try #require(screen.textFields.first)
      try screen.replaceText(in: search, with: "br")
      #expect(log.entries.suffix(2) == ["filter paused [b]", "filter paused [br]"])
    }

    @Test("the suggested templates show under the All filter only, and go away for the others")
    func suggestionsFollowFilter() throws {
      var state = AutomationsViewState(rows: [row("a")], hasAny: true)
      state.templates = cards
      let screen = page(state)
      defer { screen.close() }
      #expect(try screen.shows("Suggested"))
      try pick(.active, screen)
      #expect(try !screen.shows("Suggested"))
    }

    @Test("New opens a blank automation, as the web's button")
    func newButton() throws {
      let screen = page(AutomationsViewState(rows: [], hasAny: true))
      defer { screen.close() }
      #expect(screen.popUps.isEmpty, "New is a button, not a menu")
      try screen.clickControl(at: 0)
      #expect(log.entries == ["create blank"])
    }

  }

  extension PagesAutomationListTests {
    @Test("the Templates tab shows the gallery, or says the server offers none")
    func templatesTab() throws {
      var state = AutomationsViewState(rows: [], hasAny: true)
      let bare = page(state)
      defer { bare.close() }
      let tabs = try #require(bare.segmentedControls.first)
      #expect(tabs.segmentCount == 2, "Your automations and Templates, without Shared with me")
      try bare.click(segment: 1, of: tabs)
      #expect(try bare.shows(state.templatesUnavailable))
      state.templates = cards
      state.shared = SharedAutomationsState()
      let offered = page(state)
      defer { offered.close() }
      let allTabs = try #require(offered.segmentedControls.first)
      #expect(allTabs.segmentCount == 3)
      try offered.click(segment: 2, of: allTabs)
      #expect(try offered.shows("Requires a Linear MCP server."))
    }

    @Test("Shared with me lists other users' automations read-only, and asks for more")
    func sharedTab() throws {
      var state = AutomationsViewState(rows: [], hasAny: true)
      var shared = SharedAutomationsState()
      var theirs = row("s")
      theirs.sharedBy = "Ana"
      shared.rows = [theirs]
      shared.hasAny = true
      shared.hasMore = true
      state.shared = shared
      var actions = actions
      let log = log
      actions.loadShared = { log.record("load shared") }
      actions.loadMoreShared = { log.record("more shared") }
      let screen = page(state, actions: actions)
      defer { screen.close() }
      try screen.click(segment: 1, of: try #require(screen.segmentedControls.first))
      #expect(log.entries == ["load shared"])
      #expect(
        try screen.shows("Shared by Ana \u{00B7} Every day at 9:00 AM \u{00B7} Next run in 8 mins"))
      let menu = try #require(screen.popUps.first)
      let disabled = try screen.titles(inPopUp: menu)
      #expect(disabled.contains("Edit"))
      try screen.choose("Edit", inPopUp: menu)
      #expect(log.entries == ["load shared"], "a viewer's Edit is disabled")
      #expect(try screen.shows("Show more"), "more pages remain")
      #expect(try !screen.shows("No automations are shared with you yet"))
    }

    @Test("without a create action there is nothing to create from")
    func noCreate() throws {
      var actions = actions
      actions.create = nil
      let screen = page(AutomationsViewState(rows: [], hasAny: false), actions: actions)
      defer { screen.close() }
      #expect(screen.popUps.isEmpty)
      #expect(screen.controlFrames.count == 1, "the tabs; the search box is a plain field")
      #expect(try screen.shows("No automations yet"))
    }

    @Test("each template card creates from that template")
    func templateCards() throws {
      var state = AutomationsViewState(rows: [], hasAny: false)
      state.templates = cards
      let screen = page(state)
      defer { screen.close() }
      // New, the tabs, then the cards; the search box is a plain field.
      let buttons = screen.controlFrames.dropFirst(2)
      #expect(buttons.count == 2)
      for frame in buttons { try screen.click(CGPoint(x: frame.midX, y: frame.midY)) }
      #expect(log.entries == ["trigger jira", "trigger linear"])
      #expect(try screen.shows("Requires a Jira MCP server."))
    }

    @Test("a failed last run warns, and a trigger runs when items match, with no Run now")
    func failedAndTriggerRows() throws {
      var failed = row("f")
      failed.lastRunFailed = true
      var trigger = row("t")
      trigger.isTrigger = true
      let screen = page(AutomationsViewState(rows: [failed, trigger], hasAny: true))
      defer { screen.close() }
      #expect(try screen.shows("Runs when new items match"))
      #expect(try screen.shows("Every day at 9:00 AM \u{00B7} Next run in 8 mins"))
      let triggerMenu = try #require(screen.popUps.last)
      #expect(try !screen.titles(inPopUp: triggerMenu).contains("Run now"))
      #expect(try screen.titles(inPopUp: try #require(screen.popUps.first)).contains("Run now"))
    }

    /// A point on row `index`'s title, level with the row's menu.
    private func rowTitle<Content>(_ index: Int, _ screen: OffscreenWindow<Content>) throws
      -> CGPoint
    {
      let menu = try #require(Array(screen.popUps).dropFirst(index).first)
      let frame = menu.convert(menu.bounds, to: screen.activeWindow.contentView)
      return CGPoint(x: 120, y: frame.midY)
    }

    @Test("clicking a row opens that automation's details")
    func clickRow() throws {
      let screen = page(AutomationsViewState(rows: [row("a"), row("b")], hasAny: true))
      defer { screen.close() }
      try screen.click(try rowTitle(1, screen))
      #expect(log.entries == ["detail b"])
    }

    @Test("with no details to open, one click does nothing and a double click edits")
    func doubleClickRow() throws {
      var actions = actions
      actions.openDetail = nil
      let screen = page(
        AutomationsViewState(rows: [row("a"), row("b")], hasAny: true), actions: actions)
      defer { screen.close() }
      let title = try rowTitle(0, screen)
      // The pointer rests on the row before it clicks, as a hand's does: a row that first
      // learns of the pointer between two taps draws again and starts the double tap over.
      try screen.hover(title)
      try screen.click(title, clickCount: 1)
      #expect(log.entries.isEmpty)
      // Past the double-click interval, so the click above is no part of the double click.
      screen.settle(NSEvent.doubleClickInterval + 0.1)
      try screen.doubleClick(title)
      #expect(log.entries == ["edit a"])
    }

    @Test("a row's menu runs, edits, pauses and opens the last run of that row")
    func rowMenu() throws {
      let screen = page(
        AutomationsViewState(rows: [row("a", lastRun: "s1"), row("b", paused: true)], hasAny: true))
      defer { screen.close() }
      #expect(try screen.shows("Every day at 9:00 AM \u{00B7} Next run in 8 mins"))
      #expect(try screen.shows("Paused"))
      let menus = screen.popUps
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
      // New, the tabs, the three filter pills, Dismiss, Retry.
      try screen.clickControl(at: 5)
      #expect(log.entries == ["dismiss"])
      try screen.clickControl(at: 6)
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
    func noFilterWhenEmpty() throws {
      let screen = page(AutomationsViewState(rows: [], hasAny: false))
      defer { screen.close() }
      #expect(screen.segmentedControls.count == 1, "only the tabs")
      #expect(try !screen.shows("Paused"), "no filter pills")
    }

    @Test("every button stays in the window at a narrow width, even with a long name")
    func narrowWidth() {
      SystemSideEffects.reset()
      var state = AutomationsViewState(
        rows: [row("a")], hasAny: true)
      state.rows[0].name = String(repeating: "Long automation name ", count: 12)
      state.templates = cards
      let screen = OffscreenWindow(
        AutomationsView(state: state, actions: actions), width: 520, height: 800)
      defer { screen.close() }
      for frame in screen.controlFrames {
        #expect(frame.minX >= 0 && frame.maxX <= 520, "\(frame)")
      }
    }

    @Test("the page reads as the web's: title and New, tabs, search, filter, cards, Suggested")
    func layout() throws {
      var state = AutomationsViewState(rows: [row("a"), row("b")], hasAny: true)
      state.templates = cards
      var actions = actions
      let log = log
      actions.showIntro = { log.record("intro") }
      let screen = page(state, actions: actions)
      defer { screen.close() }
      let identifiers = [
        "automations-intro-button", "automations-new", "automations-tabs", "automations-search",
        "automations-filter-all", "automation-a", "automation-b", "automations-trigger-jira",
        "automations-trigger-linear",
      ]
      let frames = try screen.withAccessibilityTree {
        try identifiers.reduce(into: [String: CGRect]()) {
          $0[$1] = try screen.accessibilityFrame($1)
        }
      }
      func frame(_ id: String) throws -> CGRect { try #require(frames[id]) }
      let intro = try frame("automations-intro-button")
      let new = try frame("automations-new")
      #expect(abs(intro.midY - new.midY) < 8, "the guide's button and New share the title's line")
      #expect(new.minX > 600, "New sits at the right")
      let tabs = try frame("automations-tabs")
      let search = try frame("automations-search")
      let filter = try frame("automations-filter-all")
      #expect(new.maxY <= tabs.minY && tabs.maxY <= search.minY && search.maxY <= filter.minY)
      #expect(search.width > 600, "the search box spans the page")
      let first = try frame("automation-a")
      let second = try frame("automation-b")
      #expect(filter.maxY <= first.minY)
      #expect(second.minY - first.maxY < 12, "cards stack with a small gap")
      let jira = try frame("automations-trigger-jira")
      let linear = try frame("automations-trigger-linear")
      #expect(second.maxY + 24 <= jira.minY, "Suggested sits past a rule")
      #expect(abs(jira.midY - linear.midY) < 2, "two template columns")
      try screen.clickElement("automations-intro-button")
      #expect(log.entries == ["intro"])
    }
  }
#endif
