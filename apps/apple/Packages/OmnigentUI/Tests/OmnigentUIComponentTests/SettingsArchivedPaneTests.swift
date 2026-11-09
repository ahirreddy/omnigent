#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  private enum ArchivedShown {
    case all
    case none
  }

  @Suite("Archived sessions, clicked", .serialized)
  @MainActor
  struct SettingsArchivedPaneTests {
    private let log = ActionLog()
    private let store: UserDefaults
    private let now = Int64(Date.now.timeIntervalSince1970)

    init() throws {
      store = try #require(UserDefaults(suiteName: "settings-archived-\(UUID())"))
    }

    private var actions: ServerSettingsActions {
      var actions = ServerSettingsActions()
      let log = log
      actions.unarchive = { log.record("unarchive \($0.sorted())") }
      actions.delete = { log.record("delete \($0.sorted())") }
      actions.openSession = { log.record("open \($0)") }
      actions.loadMoreArchived = { log.record("more") }
      return actions
    }

    private var sessions: [SessionSummary] {
      [
        SessionSummary(
          id: "mine", title: "My session", updatedAt: now, workspace: "repo", agentName: "Codex"),
        SessionSummary(id: "theirs", title: "Their session", updatedAt: now),
      ]
    }

    private var info: [String: ArchivedSessionInfo] {
      let old = now - 40 * 86_400
      return [
        "mine": ArchivedSessionInfo(projectID: "p1", archivedAt: old, canDelete: true),
        "theirs": ArchivedSessionInfo(projectID: "p2", archivedAt: old, canDelete: false),
      ]
    }

    private func screen(
      showing shownSessions: ArchivedShown = .all, hasMore: Bool = false,
      actions: ServerSettingsActions? = nil, projects: [SettingChoice] = []
    ) -> OffscreenWindow<some View> {
      let sessions = shownSessions == .all ? self.sessions : []
      let info = info
      let actions = actions ?? self.actions
      return settingsForm(store: store) {
        ArchivedSessionsPane(
          sessions: sessions, info: info, projects: projects, hasMore: hasMore, actions: actions)
      }
    }

    /// Reading order with no retention set: Select all, then each row's check, Unarchive and,
    /// for your own session, trash; the bulk buttons join once something is selected.
    private func click<Content>(_ index: Int, _ screen: OffscreenWindow<Content>) throws {
      try screen.clickButton(at: index)
    }

    @Test("no sessions says so and offers no selection")
    func empty() throws {
      let screen = screen(showing: .none)
      defer { screen.close() }
      #expect(try screen.shows("No archived sessions."))
      #expect(try !screen.shows("Select all"))
      #expect(screen.buttonFrames.isEmpty)
    }

    @Test("a row shows what ran where; Unarchive restores and opens that session")
    func rowUnarchive() throws {
      let screen = screen()
      defer { screen.close() }
      #expect(try screen.shows("My session"))
      #expect(try screen.shows("Codex \u{00B7} repo"))
      #expect(try screen.shows("Today"))
      // Select all, this row's check, then this row's Unarchive.
      try click(2, screen)
      #expect(log.entries == ["unarchive [\"mine\"]", "open mine"])
    }

    @Test("only your own session has a delete, and it asks first")
    func rowDelete() throws {
      let screen = screen()
      defer { screen.close() }
      // Select all; check, Unarchive, trash; check, Unarchive.
      #expect(screen.buttonFrames.count == 6)
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      try click(3, screen)
      #expect(SystemSideEffects.record.alertMessages == ["Delete 1 session?"])
      #expect(log.entries.isEmpty)
      SystemSideEffects.answer(alert: .alertFirstButtonReturn)
      try click(3, screen)
      #expect(log.entries == ["delete [\"mine\"]"])
    }

    @Test("without the actions, rows offer neither")
    func rowsWithoutActions() throws {
      let screen = screen(actions: ServerSettingsActions())
      defer { screen.close() }
      // Select all and each row's check.
      #expect(screen.buttonFrames.count == 3)
    }

    @Test("selecting all counts them; Unarchive sends them and clears the selection")
    func selectAll() throws {
      let screen = screen()
      defer { screen.close() }
      #expect(try screen.shows("Select all"))
      try click(0, screen)
      #expect(try screen.shows("2 selected"))
      // Selected: Unarchive and Delete join the bar after the check.
      try click(1, screen)
      #expect(log.entries == ["unarchive [\"mine\", \"theirs\"]"])
      #expect(try screen.shows("Select all"))
    }

    @Test("clicking select all again clears it; a row's check counts by itself")
    func selectOne() throws {
      let screen = screen()
      defer { screen.close() }
      try click(0, screen)
      try click(0, screen)
      #expect(try screen.shows("Select all"))
      // Select all, then the first row's check.
      try click(1, screen)
      #expect(try screen.shows("1 selected"))
    }

    @Test("bulk delete only sends what you may delete, after asking")
    func bulkDelete() throws {
      let screen = screen()
      defer { screen.close() }
      try click(0, screen)
      SystemSideEffects.answer(alert: .alertFirstButtonReturn)
      // The check, Unarchive, Delete.
      try click(2, screen)
      #expect(SystemSideEffects.record.alertMessages == ["Delete 1 session?"])
      #expect(log.entries == ["delete [\"mine\"]"])
      #expect(try screen.shows("1 selected"), "the one you can't delete stays selected")
    }

    @Test("a retention marks old sessions, and Delete Expired takes only yours")
    func retention() throws {
      let screen = screen()
      defer { screen.close() }
      #expect(try !screen.shows("past the"))
      try screen.choose("After 30 days", inPopUp: try #require(screen.popUps.first))
      #expect(store.string(forKey: ArchivedRetention.key) == "30")
      #expect(try screen.shows("1 session past the 30-day retention"))
      SystemSideEffects.answer(alert: .alertFirstButtonReturn)
      try click(0, screen)
      #expect(SystemSideEffects.record.alertMessages == ["Delete 1 session?"])
      #expect(log.entries == ["delete [\"mine\"]"])
      try screen.choose("Never", inPopUp: try #require(screen.popUps.first))
      #expect(store.string(forKey: ArchivedRetention.key) == nil)
      #expect(try !screen.shows("past the"))
    }

    @Test("a retention's count admits it has only seen the loaded pages")
    func retentionWithMorePages() throws {
      store.set("30", forKey: ArchivedRetention.key)
      let screen = screen(hasMore: true)
      defer { screen.close() }
      #expect(try screen.shows("1 session on loaded pages past the 30-day retention"))
      let load = try #require(screen.buttonFrames.last)
      try screen.click(CGPoint(x: load.midX, y: load.midY))
      #expect(log.entries == ["more"])
    }

    @Test("a retention still inside its days marks nothing")
    func retentionNotReached() throws {
      store.set("60", forKey: ArchivedRetention.key)
      let screen = screen()
      defer { screen.close() }
      #expect(try !screen.shows("past the"))
    }

    @Test("the project filter narrows the list, and All brings it back")
    func projectFilter() throws {
      let projects = [
        SettingChoice(id: "p1", title: "One"), SettingChoice(id: "p2", title: "Two"),
      ]
      let screen = screen(projects: projects)
      defer { screen.close() }
      let picker = try #require(screen.popUps.last)
      #expect(try screen.titles(inPopUp: picker) == ["All projects", "One", "Two"])
      try screen.choose("Two", inPopUp: picker)
      #expect(try screen.shows("Their session"))
      #expect(try !screen.shows("My session"))
      try screen.choose("All projects", inPopUp: try #require(screen.popUps.last))
      #expect(try screen.shows("My session"))
    }

    @Test("selected rows a filter hides aren't acted on")
    func filterHidesSelection() throws {
      let projects = [SettingChoice(id: "p2", title: "Two")]
      let screen = screen(projects: projects)
      defer { screen.close() }
      try click(0, screen)
      try screen.choose("Two", inPopUp: try #require(screen.popUps.last))
      #expect(try screen.shows("1 selected"))
      try click(1, screen)
      #expect(log.entries == ["unarchive [\"theirs\"]"])
    }

    @Test("a right click on a row offers the same actions")
    func contextMenu() throws {
      let screen = screen()
      defer { screen.close() }
      // The row's title, just past its check.
      let check = screen.buttonFrames[1]
      let menu = try #require(
        try screen.contextMenu(at: CGPoint(x: check.maxX + 20, y: check.midY)))
      #expect(menu.items.map(\.title) == ["Delete\u{2026}", "Unarchive"])
      try screen.choose("Unarchive", in: menu)
      #expect(log.entries == ["unarchive [\"mine\"]", "open mine"])
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      try screen.choose("Delete\u{2026}", in: menu)
      #expect(SystemSideEffects.record.alertMessages.count == 1, "asks before deleting")
      #expect(log.entries.count == 2, "declined")
    }
  }
#endif
