import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import Testing

@testable import OmnigentAppUI

/// What the sidebar's rows and menus do to the sessions and to the window's tabs.
@MainActor
@Suite("Sidebar actions", .serialized, .timeLimit(.minutes(1)))
struct SidebarActionsTests {
  private func summary(_ session: ServerSession, _ id: String) throws
    -> OmnigentUIComponents.SessionSummary
  {
    OmnigentUIComponents.SessionSummary(try #require(session.connection.sessionList.session(id)))
  }

  @Test("Archiving closes the session's tabs and offers Undo, which restores it")
  func archiveAndUndo() async throws {
    let server = threeSessionServer()
    let session = try await signedInSession(server)
    let view = connectedView(session, WindowSelection())
    session.tabs.showChat("conv_a")
    view.edit(.archive(["conv_a"], true))
    try await eventually("the Undo bar") { view.sidebarModel.undo != nil }
    #expect(session.tabs.groups["conv_a"] == nil, "an archived session's tabs leave with it")
    #expect(view.sidebarModel.undo?.banner?.kind == .archived(count: 1))
    let archive = try #require(try server.patched("/v1/sessions/conv_a").last)
    #expect(archive["archived"] as? Bool == true)

    view.sidebarActions.undo?(try #require(view.sidebarModel.undo?.banner))
    try await eventually("the restore") {
      (try? server.patched("/v1/sessions/conv_a").count) == 2
    }
    #expect(try server.patched("/v1/sessions/conv_a").last?["archived"] as? Bool == false)
    #expect(view.sidebarModel.undo == nil, "Undo can't be undone from the bar")
  }

  @Test("An archive the server refuses keeps the session's tabs and says why")
  func aRefusedArchiveKeepsTabs() async throws {
    let server = threeSessionServer()
    server.route("/v1/sessions/conv_a", method: "PATCH", .json(#"{"detail":"nope"}"#, status: 422))
    let session = try await signedInSession(server)
    let view = connectedView(session, WindowSelection())
    session.tabs.showChat("conv_a")
    view.edit(.archive(["conv_a"], true))
    try await eventually("the failure") { session.connection.sessionList.editError != nil }
    try await eventually("the edit to end") { session.connection.sessionList.editing.isEmpty }
    try await Task.sleep(for: .milliseconds(20))
    #expect(session.tabs.groups["conv_a"] != nil, "the session wasn't archived")
    #expect(view.sidebarModel.undo == nil)
  }

  @Test("Archiving several stops at a refusal: only those archived lose their tabs")
  func aPartlyRefusedArchive() async throws {
    let server = threeSessionServer()
    server.route("/v1/sessions/conv_b", method: "PATCH", .json(#"{"detail":"nope"}"#, status: 422))
    let session = try await signedInSession(server)
    let view = connectedView(session, WindowSelection())
    for id in ["conv_a", "conv_b", "conv_c"] { session.tabs.showChat(id) }
    view.edit(.archive(["conv_a", "conv_b", "conv_c"], true))
    try await eventually("the failure") { session.connection.sessionList.editError != nil }
    try await Task.sleep(for: .milliseconds(20))
    #expect(session.tabs.groups["conv_a"] == nil)
    #expect(session.tabs.groups["conv_b"] != nil)
    #expect(session.tabs.groups["conv_c"] != nil, "it was never tried")
    #expect(try server.patched("/v1/sessions/conv_c").isEmpty)
  }

  @Test("Pinning offers Undo with the right words")
  func pinAndUndo() async throws {
    let server = threeSessionServer()
    let session = try await signedInSession(server)
    let view = connectedView(session, WindowSelection())
    let row = try summary(session, "conv_b")
    view.sessionListActions.setPinned?(row, true)
    try await eventually("the Undo bar") { view.sidebarModel.undo != nil }
    #expect(view.sidebarModel.undo?.banner?.kind == .pinned)
    view.sidebarActions.dismissUndo?()
    #expect(view.sidebarModel.undo == nil)
  }

  @Test("Deleting closes the tabs only once it's gone")
  func deleteClosesTabs() async throws {
    let server = threeSessionServer()
    server.route("/v1/sessions/conv_a", method: "DELETE", .json(#"{"deleted":true}"#))
    server.route("/v1/sessions/conv_b", method: "DELETE", .json(#"{"detail":"no"}"#, status: 422))
    let session = try await signedInSession(server)
    let view = connectedView(session, WindowSelection())
    session.tabs.showChat("conv_a")
    session.tabs.showChat("conv_b")
    view.sessionListActions.delete?(try summary(session, "conv_b"))
    try await eventually("the refused delete") { session.connection.sessionList.editError != nil }
    #expect(session.tabs.groups["conv_b"] != nil)
    view.sessionListActions.delete?(try summary(session, "conv_a"))
    try await eventually("the delete") { session.tabs.groups["conv_a"] == nil }
    #expect(session.tabs.groups["conv_b"] != nil)
  }

  @Test("Previous and Next follow the sidebar's order and wrap at the ends")
  func previousAndNext() async throws {
    let session = try await signedInSession(threeSessionServer())
    let selection = WindowSelection(.session("conv_a"))
    let view = connectedView(session, selection)
    let actions = view.navigation(from: "conv_a")
    actions.nextSession?()
    #expect(selection.page == .session("conv_b"))
    actions.previousSession?()
    #expect(selection.page == .session("conv_c"), "Previous from the first wraps to the last")
  }

  @Test("With one session there's nowhere to step")
  func aloneThereIsNoStep() async throws {
    let server = newSessionServer()
    let row = sessionRow("conv_a", host: "mac", workspace: "/w", updatedAt: 5)
    server.route(
      "/v1/sessions", method: "GET", .json(#"{"object":"list","data":[\#(row)],"has_more":false}"#))
    let session = try await signedInSession(server)
    let actions = connectedView(session, WindowSelection()).navigation(from: "conv_a")
    #expect(actions.nextSession == nil)
    #expect(actions.previousSession == nil)
  }

  @Test("A pinned shortcut opens that pin, and one past the end does nothing")
  func pinnedShortcuts() async throws {
    let server = threeSessionServer()
    let pinned =
      #"{"id":"conv_a","status":"idle","created_at":1,"updated_at":5,"host_id":"mac","workspace":"/w","permission_level":4,"archived":false,"pinned":true,"labels":{"omnigent.pinned":"1"}}"#
    server.route(
      "/v1/sessions", method: "GET",
      .json(#"{"object":"list","data":[\#(pinned)],"has_more":false}"#))
    let session = try await signedInSession(server)
    let selection = WindowSelection()
    let view = connectedView(session, selection)
    view.openPinnedSession(99)
    #expect(selection.page == nil)
    if session.connection.sessionList.session("conv_a")?.isPinned == true {
      view.openPinnedSession(0)
      #expect(selection.page == .session("conv_a"))
    } else {
      Issue.record("the fixture's session must read as pinned")
    }
  }

  @Test("New Session in a project opens the form on that project")
  func newSessionInAProject() async throws {
    let session = try await signedInSession(threeSessionServer())
    let selection = WindowSelection()
    let view = connectedView(session, selection)
    view.newSession(in: SessionProject(id: "p1", name: "Alpha", sessionIds: [], icon: nil))
    #expect(selection.page == .newSession)
    #expect(session.connection.creation()?.pendingProject?.name == "Alpha")
  }

  @Test("Show > Archived is the archived list, and a quick filter leaves it")
  func archivedAndQuickFilter() async throws {
    defer { UserDefaults.standard.removeObject(forKey: SidebarDisplayDefaults.key) }
    let session = try await signedInSession(threeSessionServer())
    let view = connectedView(session, WindowSelection())
    let list = session.connection.sessionList
    view.setDisplay(view.sidebarModel.display.with(show: .archived))
    #expect(list.filter == .archived)
    #expect(SidebarDisplayDefaults.load().show == .archived, "kept across launches")

    view.setQuickFilter(nil)
    #expect(list.filter == .all)
    #expect(view.sidebarModel.display.show == .all)

    view.setDisplay(view.sidebarModel.display.with(show: .archived))
    view.setDisplay(view.sidebarModel.display.with(show: .all))
    #expect(list.filter == .all, "leaving Archived shows everything again")
  }

  @Test("Saved display options that no longer decode fall back to the defaults")
  func oldDisplayOptions() throws {
    let defaults = try scratchDefaults()
    defaults.set(Data("not json".utf8), forKey: SidebarDisplayDefaults.key)
    #expect(SidebarDisplayDefaults.load(defaults).show == SessionDisplayOptions().show)
    #expect(defaults.data(forKey: SidebarDisplayDefaults.key) == nil)
  }

  @Test("The switcher lists each server once and flags the organization's")
  func serverChoices() throws {
    let one = try #require(URL(string: "https://one.example/"))
    let sameOne = try #require(URL(string: "https://ONE.example"))
    let two = try #require(URL(string: "https://two.example"))
    let twoAgain = try #require(URL(string: "https://two.example/"))
    let switching = ServerSwitching(
      servers: [one, sameOne, two], organizationServers: [twoAgain],
      switchTo: { _ in }, addServer: {})
    #expect(switching.choices.map(\.id) == ["https://one.example", "https://two.example"])
    #expect(switching.choices.map(\.isOrganization) == [false, true])
  }

  @Test("Switching a server and adding one go to the host")
  func switchingServers() async throws {
    let session = try await signedInSession(threeSessionServer())
    var moved: [URL] = []
    var added = 0
    let switching = ServerSwitching(
      servers: [], switchTo: { moved.append($0) }, addServer: { added += 1 })
    let actions = connectedView(session, WindowSelection(), serverSwitching: switching)
      .sidebarActions
    let target = "https://two.example"
    actions.switchServer?(
      ServerChoice(id: target, name: "two", url: target, isConnected: false, isOrganization: false))
    actions.addServer?()
    #expect(moved == [URL(string: target)])
    #expect(added == 1)
  }

  @Test("A link to this server's own session opens here; another site goes to the browser")
  func links() async throws {
    let session = try await signedInSession(threeSessionServer())
    let selection = WindowSelection()
    var browser: [URL] = []
    let fallback = ExternalURLOpener { url in
      browser.append(url)
      return true
    }
    let view = connectedView(session, selection)
    let opener = view.serverLinkOpener(fallback, openSettings: nil)
    let base = "http://127.0.0.1:6767"
    _ = await opener.open(try #require(URL(string: "\(base)/c/conv_b")))
    #expect(selection.page == .session("conv_b"))
    _ = await opener.open(try #require(URL(string: "\(base)/c/conv_c?message=m1")))
    #expect(selection.page == .session("conv_c"))
    _ = await opener.open(try #require(URL(string: "\(base)/usage")))
    #expect(selection.page == .usage)
    _ = await opener.open(try #require(URL(string: "\(base)/")))
    #expect(selection.page == nil)
    #expect(browser.isEmpty)
    _ = await opener.open(try #require(URL(string: "\(base)/settings/git")))
    #expect(browser.count == 1, "with no Settings here, the browser shows it")
    _ = await opener.open(try #require(URL(string: "https://example.com/")))
    #expect(browser.last == URL(string: "https://example.com/"))
  }
}
