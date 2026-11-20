#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  @Suite("Automations page, sorted and cloned", .serialized)
  @MainActor
  struct PagesAutomationListOrderTests {
    private let log = ActionLog()

    private func row(_ id: String) -> AutomationRow {
      AutomationRow(
        id: id, name: "Automation \(id)", scheduleText: "Every day at 9:00 AM",
        nextRunText: "in 8 mins", isPaused: false)
    }

    private func page(_ rows: [AutomationRow], actions: AutomationsActions)
      -> OffscreenWindow<AutomationsView>
    {
      SystemSideEffects.reset()
      return OffscreenWindow(
        AutomationsView(state: AutomationsViewState(rows: rows, hasAny: true), actions: actions),
        width: 1_000, height: 800)
    }

    private var baseActions: AutomationsActions {
      var actions = AutomationsActions()
      actions.filter = { _, _ in }
      actions.edit = { _ in }
      return actions
    }

    @Test("Clone shows only where the server clones, and clones that row")
    func cloneFromTheRowMenu() throws {
      let plain = page([row("a")], actions: baseActions)
      #expect(try !plain.titles(inPopUp: try #require(plain.popUps.first)).contains("Clone"))
      plain.close()
      var actions = baseActions
      let log = log
      actions.clone = { log.record("clone \($0)") }
      let screen = page([row("a"), row("b")], actions: actions)
      defer { screen.close() }
      try screen.choose("Clone", inPopUp: try #require(screen.popUps.last))
      #expect(log.entries == ["clone b"])
    }

    @Test("Sort By orders by next run or name once there is a sort action")
    func sortMenu() throws {
      let plain = page([row("a")], actions: baseActions)
      #expect(plain.popUps.count == 1, "only the row's menu without a sort action")
      plain.close()
      var actions = baseActions
      let log = log
      actions.sort = { log.record("sort \($0.rawValue)") }
      let screen = page([row("a")], actions: actions)
      defer { screen.close() }
      let sort = try #require(
        screen.popUps.first { (try? screen.titles(inPopUp: $0))?.contains("Name") == true })
      try screen.choose("Name", inPopUp: sort)
      #expect(log.entries == ["sort name"])
    }
  }
#endif
