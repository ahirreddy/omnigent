import Testing

@testable import OmnigentUIComponents

@Suite("Sidebar arrangement")
struct SidebarArrangementTests {
  @Test("An arrangement is the sections and their rows' order, not what the rows say")
  func arrangement() {
    let sessions = [
      SessionSummary(id: "a", title: "A", updatedAt: 2),
      SessionSummary(id: "b", title: "B", updatedAt: 1),
    ]
    let state = SidebarViewState(list: SessionListViewState(sessions: sessions))
    var talks = state
    talks.list.sessions[0].preview = "A new message"
    talks.list.unreadIds = ["b"]
    #expect(SidebarArrangement(talks) == SidebarArrangement(state))
    var pinned = state
    pinned.list.sessions[1].isPinned = true
    #expect(SidebarArrangement(pinned) != SidebarArrangement(state), "a row changed section")
    var grouped = state
    grouped.display.groupBy = .status
    var regrouped = grouped
    regrouped.list.unreadIds = ["b"]
    #expect(SidebarArrangement(regrouped) != SidebarArrangement(grouped), "a new section")
  }
}

#if os(macOS)
  import AppKit
  import Observation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI

  /// Rows and counts a host keeps beside the sidebar's state, as the app's session list does.
  @MainActor
  @Observable
  final class SidebarLiveSource {
    var rows: [String: SidebarRowContent] = [:]
    var counts = SidebarCounts()
    /// Whether each session's row was last read with its draft.
    @ObservationIgnored var draftReads: [String: Bool] = [:]

    var live: SidebarLive {
      SidebarLive(
        row: { [self] sessionID, showsDraft in
          draftReads[sessionID] = showsDraft
          return rows[sessionID]
        }, counts: { [self] in counts })
    }
  }

  /// The sidebar drawing sessions as they are now: a row, a count or a collapsed header's marker
  /// shows a change the sidebar's own state does not have.
  @Suite("Sidebar live rows", .serialized)
  @MainActor
  struct SidebarLiveTests {
    private static let now: Int64 = 100_000

    /// Beta was updated three minutes ago and Gamma five.
    private static var state: SidebarViewState {
      var state = SidebarViewState(
        list: SessionListViewState(sessions: [
          SessionSummary(id: "beta", title: "Beta", updatedAt: now - 180),
          SessionSummary(id: "gamma", title: "Gamma", updatedAt: now - 300),
        ]))
      state.list.now = Date(timeIntervalSince1970: TimeInterval(now))
      return state
    }

    private func sidebar(_ spy: SidebarSpy, _ source: SidebarLiveSource?) -> OffscreenWindow<
      AnyView
    > {
      var actions = spy.actions
      actions.live = source?.live
      return OffscreenWindow(
        AnyView(SidebarHarness(spy: spy, actions: actions)), width: 340, height: 800)
    }

    private func needsYouLabels(_ screen: OffscreenWindow<AnyView>) throws -> Int {
      try screen.shownText().filter { $0 == "Needs you" }.count
    }

    @Test("A row draws its session as it is now, and the state's where the host has none")
    func rowDrawsTheLiveSession() throws {
      let spy = SidebarSpy(Self.state)
      let source = SidebarLiveSource()
      source.rows["beta"] = SidebarRowContent(
        session: SessionSummary(id: "beta", title: "Renamed", updatedAt: Self.now - 7_200))
      let screen = sidebar(spy, source)
      defer { screen.close() }
      var shown = try screen.shownText()
      #expect(shown.contains("Renamed") && !shown.contains("Beta"))
      #expect(shown.contains("2h") && !shown.contains("3m"))
      #expect(shown.contains("Gamma") && shown.contains("5m"), "the state's row")
      let labels = try needsYouLabels(screen)

      source.rows["beta"]?.session.title = "Renamed again"
      source.rows["beta"]?.session.attention = .needsYou
      screen.settle()
      shown = try screen.shownText()
      #expect(shown.contains("Renamed again") && !shown.contains("Renamed"))
      #expect(try needsYouLabels(screen) == labels + 1, "the row's, beside the filter's title")
      #expect(spy.state == Self.state, "the list's state did not change")
    }

    @Test(
      "The open session's row keeps its time; another row's draft takes the time's place",
      arguments: [true, false])
    func openRowHidesItsDraft(isLive: Bool) throws {
      var state = Self.state
      let drafted = SessionRowInfo(hasDraft: true)
      state.rowInfo = ["beta": drafted, "gamma": drafted]
      let spy = SidebarSpy(state)
      spy.selection = .session("beta")
      let source = SidebarLiveSource()
      for session in state.list.sessions {
        source.rows[session.id] = SidebarRowContent(session: session, info: drafted)
      }
      let screen = sidebar(spy, isLive ? source : nil)
      defer { screen.close() }
      var shown = try screen.shownText()
      #expect(shown.contains("3m") && !shown.contains("5m"))
      if isLive { #expect(source.draftReads == ["beta": false, "gamma": true]) }

      spy.selection = .session("gamma")
      screen.settle()
      shown = try screen.shownText()
      #expect(!shown.contains("3m") && shown.contains("5m"))
      if isLive { #expect(source.draftReads == ["beta": true, "gamma": false]) }
    }

    @Test("The quick filters count what the host counts now")
    func countsAreLive() throws {
      var state = Self.state
      state.list.filterCounts = [.running: 21]
      let spy = SidebarSpy(state)
      let stated = sidebar(spy, nil)
      defer { stated.close() }
      #expect(try stated.shownText().contains("21"), "the state's count")

      let source = SidebarLiveSource()
      source.counts = SidebarCounts(inbox: 34, filters: [.running: 55, .needsResponse: 89])
      let screen = sidebar(spy, source)
      defer { screen.close() }
      var shown = try screen.shownText()
      #expect(shown.contains("55") && shown.contains("89") && !shown.contains("21"))
      source.counts.filters[.running] = 144
      screen.settle()
      shown = try screen.shownText()
      #expect(shown.contains("144") && !shown.contains("55"))
    }

    @Test("A collapsed section's header marks a hidden session that needs the user now")
    func collapsedSectionMarker() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let source = SidebarLiveSource()
      let screen = sidebar(spy, source)
      defer { screen.close() }
      screen.sectionToggles[2].performClick(nil)
      screen.settle(0.3)
      #expect(try !screen.shows("Gamma"), "the Sessions rows are hidden")
      let labels = try needsYouLabels(screen)

      var gamma = SidebarFixture.gamma
      gamma.attention = .needsYou
      source.rows["gamma"] = SidebarRowContent(session: gamma, requests: 3)
      screen.settle()
      #expect(try needsYouLabels(screen) == labels + 1, "the header's, beside the filter's title")
      #expect(try screen.shownText().contains("3"), "its requests")
    }

    @Test("A collapsed folder's header marks a session inside it that needs the user now")
    func collapsedFolderMarker() throws {
      var state = SidebarFixture.state
      state.projects = [SessionProject(id: "p", name: "Work", sessionIds: ["beta"])]
      let spy = SidebarSpy(state)
      let source = SidebarLiveSource()
      let screen = sidebar(spy, source)
      defer { screen.close() }
      #expect(try screen.shows("Work") && !screen.shows("Beta"), "the folder is collapsed")
      let labels = try needsYouLabels(screen)

      var beta = SidebarFixture.beta
      beta.attention = .needsYou
      source.rows["beta"] = SidebarRowContent(session: beta)
      screen.settle()
      #expect(try needsYouLabels(screen) == labels + 1, "the folder's, beside the filter's title")
    }

    @Test("Delete archives the open session only if it can be archived now")
    func deleteReadsTheLiveSession() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let source = SidebarLiveSource()
      var beta = SidebarFixture.beta
      beta.canArchive = false
      source.rows["beta"] = SidebarRowContent(session: beta)
      let screen = sidebar(spy, source)
      defer { screen.close() }
      let delete = #selector(NSText.delete(_:))
      let list = try #require(screen.list)
      screen.window.makeFirstResponder(list)
      spy.selection = .session("beta")
      screen.settle(0.05)
      _ = list.tryToPerform(delete, with: nil)
      screen.settle(0.05)
      #expect(spy.calls.isEmpty)

      source.rows["beta"]?.session.canArchive = true
      screen.settle(0.05)
      _ = list.tryToPerform(delete, with: nil)
      screen.settle(0.05)
      #expect(spy.calls == ["archive beta true"])
    }

    @Test("A double click renames from the title the session has now")
    func doubleClickReadsTheLiveSession() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let source = SidebarLiveSource()
      var beta = SidebarFixture.beta
      beta.title = "Renamed"
      source.rows["beta"] = SidebarRowContent(session: beta)
      let screen = sidebar(spy, source)
      defer { screen.close() }
      let point = try screen.center(ofRow: SidebarFixture.betaRow)
      try screen.click(point, clickCount: 1)
      try screen.click(point, clickCount: 2)
      screen.settle(0.2)
      #expect(try #require(screen.firstTextField).stringValue == "Renamed")
    }

    @Test("The selection bar reads and deletes by what the selected sessions are now")
    func bulkBarReadsLiveRows() throws {
      let one = SessionSummary(id: "one", title: "One")
      let two = SessionSummary(id: "two", title: "Two")
      let spy = SidebarSpy(SidebarFixture.state)
      let source = SidebarLiveSource()
      source.rows["one"] = SidebarRowContent(session: one, isUnread: true)
      source.rows["two"] = SidebarRowContent(session: two, info: SessionRowInfo(isShared: true))
      var actions = spy.actions
      actions.live = source.live
      let bar = BulkActionBar(
        selected: [one, two], state: spy.state, actions: actions,
        exit: { spy.calls.append("exit") }, clear: { spy.calls.append("clear") },
        confirmDelete: { spy.calls.append("confirm \($0.map(\.id).joined(separator: ","))") }
      )
      .frame(width: 320, height: 60)
      let screen = OffscreenWindow(bar, width: 320, height: 60)
      defer { screen.close() }
      // Exit, Mark as read, Archive, Delete 1.
      try screen.clickControl(at: 1)
      #expect(spy.calls == ["unread one false", "exit"])
      try screen.clickControl(at: 3)
      #expect(spy.calls.last == "confirm one")
    }
  }
#endif
