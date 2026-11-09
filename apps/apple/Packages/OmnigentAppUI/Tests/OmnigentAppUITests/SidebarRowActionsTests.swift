import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI

/// What a sidebar row's menu and drags send, and the sheets a row opens.
@MainActor
@Suite("Sidebar row actions", .serialized, .timeLimit(.minutes(1)))
struct SidebarRowActionsTests {
  private let project = SessionProject(
    id: "p1", name: "Alpha", sessionIds: [], projectID: "p1", icon: nil)

  /// A signed-in window over `server`, listing `conv_a`, `conv_b` and `conv_c`.
  private func opened(_ server: AppServer = threeSessionServer()) async throws -> (
    ConnectedServerView, ServerSession
  ) {
    let session = try await signedInSession(server)
    return (connectedView(session, WindowSelection()), session)
  }

  private func summary(_ session: ServerSession, _ id: String = "conv_a") throws
    -> OmnigentUIComponents.SessionSummary
  {
    OmnigentUIComponents.SessionSummary(try #require(session.connection.sessionList.session(id)))
  }

  /// The pin label an edit sends: a stamp pins, empty unpins.
  private func pinLabel(_ edit: [String: Any]) -> String? {
    (edit["labels"] as? [String: Any])?["omnigent.pinned"] as? String
  }

  @Test("Dropping on a project files it, and unpins a pinned row")
  func droppingOnAProject() async throws {
    let server = threeSessionServer()
    let (view, session) = try await opened(server)
    view.drop(try summary(session), .move(to: project, unpin: true))
    try await eventually("both edits") { (try? server.patched("/v1/sessions/conv_a").count) == 2 }
    let edits = try server.patched("/v1/sessions/conv_a")
    #expect(edits.first?["project_id"] as? String == "p1")
    #expect(pinLabel(edits.last ?? [:])?.isEmpty == true, "unpinned")
  }

  @Test("Dropping out of a project takes it out, and unpins a pinned row")
  func droppingOutOfAProject() async throws {
    let server = threeSessionServer()
    let (view, session) = try await opened(server)
    view.drop(try summary(session), .ungroup(unpin: true))
    try await eventually("both edits") { (try? server.patched("/v1/sessions/conv_a").count) == 2 }
    #expect(pinLabel(try server.patched("/v1/sessions/conv_a").last ?? [:])?.isEmpty == true)
  }

  @Test("Dropping on the pins pins it, into a row's slot when dropped on one")
  func droppingOnThePins() async throws {
    let server = threeSessionServer()
    let (view, session) = try await opened(server)
    view.drop(try summary(session), .pin(slotOf: nil))
    try await eventually("the pin") { (try? server.patched("/v1/sessions/conv_a").count) == 1 }
    #expect(pinLabel(try server.patched("/v1/sessions/conv_a").last ?? [:])?.isEmpty == false)

    view.drop(try summary(session), .unpin)
    try await eventually("the unpin") { (try? server.patched("/v1/sessions/conv_a").count) == 2 }
    #expect(pinLabel(try server.patched("/v1/sessions/conv_a").last ?? [:])?.isEmpty == true)

    view.drop(try summary(session), .none)
    view.drop(try summary(session), .pin(slotOf: "conv_b"))
    try await eventually("the move") { session.connection.sessionList.editing.isEmpty }
    try await Task.sleep(for: .milliseconds(20))
    #expect(try server.patched("/v1/sessions/conv_a").count >= 2)
  }

  @Test("A row's menu renames, marks unread, stops, moves and leaves")
  func rowMenu() async throws {
    let server = threeSessionServer()
    let (view, session) = try await opened(server)
    let row = try summary(session)
    let actions = view.sessionListActions

    actions.rename?(row, "Renamed")
    try await eventually("the rename") { (try? server.patched("/v1/sessions/conv_a").count) == 1 }
    #expect(try server.patched("/v1/sessions/conv_a").last?["title"] as? String == "Renamed")

    actions.setUnread?(row, true)
    try await eventually("the mark") {
      session.connection.sessionList.unreadIDs.contains("conv_a")
    }
    actions.moveToProject?(row, project)
    try await eventually("the move") { (try? server.patched("/v1/sessions/conv_a").count) == 2 }
    #expect(try server.patched("/v1/sessions/conv_a").last?["project_id"] as? String == "p1")

    actions.stop?(row)
    try await eventually("the stop") {
      !server.requests("POST", "/v1/sessions/conv_a/events").isEmpty
    }
  }

  @Test("Delete with its branch tells the server, and the tabs close once it's gone")
  func deleteWithBranch() async throws {
    let server = threeSessionServer()
    server.route("/v1/sessions/conv_a", method: "DELETE", .json(#"{"deleted":true}"#))
    let (view, session) = try await opened(server)
    session.tabs.showChat("conv_a")
    view.sessionListActions.deleteWithBranch?(try summary(session), true)
    try await eventually("the tabs") { session.tabs.groups["conv_a"] == nil }
    #expect(!server.requests("DELETE", "/v1/sessions/conv_a").isEmpty)
  }

  @Test("A session opens in a new window where the host offers one")
  func openInANewWindow() async throws {
    let session = try await signedInSession(threeSessionServer())
    final class Opened { var ids: [String] = [] }
    let opened = Opened()
    let view = connectedView(session, WindowSelection(), openInNewWindow: { opened.ids.append($0) })
    view.sessionListActions.openInNewWindow?(try summary(session))
    #expect(opened.ids == ["conv_a"])
    #expect(connectedView(session, WindowSelection()).sessionListActions.openInNewWindow == nil)
  }

  @Test("Restoring skips the worktree question; archiving several uses the same path")
  func restoring() async throws {
    let server = threeSessionServer()
    let (view, session) = try await opened(server)
    view.requestArchive(["conv_a"], archived: false)
    try await eventually("the restore") { (try? server.patched("/v1/sessions/conv_a").count) == 1 }
    #expect(try server.patched("/v1/sessions/conv_a").last?["archived"] as? Bool == false)

    view.sidebarActions.setArchivedMany?([try summary(session, "conv_b")], true)
    try await eventually("the archive") { (try? server.patched("/v1/sessions/conv_b").count) == 1 }
    #expect(try server.patched("/v1/sessions/conv_b").last?["archived"] as? Bool == true)
  }

  /// `conv_w` works in a git worktree, on a server that can remove them.
  private func worktreeServer() -> AppServer {
    let server = threeSessionServer()
    let row =
      #"{"id":"conv_w","status":"idle","created_at":1,"updated_at":40,"host_id":"mac","workspace":"/wt","permission_level":4,"git_branch":"feature","agent_id":"ag_claude"}"#
    server.route(
      "/v1/sessions", method: "GET",
      .json(#"{"object":"list","data":[\#(row)],"has_more":false}"#))
    server.route("/v1/sessions/conv_w", .json(row))
    return server
  }

  @Test("Archiving a worktree session asks; remembering the answer saves it for next time")
  func theWorktreeQuestion() async throws {
    let server = worktreeServer()
    let (view, session) = try await opened(server)
    server.route("/v1/info", .json(#"{"single_user":true,"archive_worktree_cleanup":true}"#))
    _ = await session.connection.pages?.loadOffered()
    let key = GitPreferences.deleteWorktreesOnArchiveKey
    UserDefaults.standard.removeObject(forKey: key)
    defer { UserDefaults.standard.removeObject(forKey: key) }

    view.requestArchive(["conv_w"], archived: true)
    let request = try #require(view.sidebarModel.archiveRequest)
    #expect(request.worktreeSessionIDs == ["conv_w"])

    view.archiveAnswered(request, delete: true, remember: true)
    #expect(UserDefaults.standard.string(forKey: key) == "true")
    try await eventually("the archive") { (try? server.patched("/v1/sessions/conv_w").count) == 1 }
    let archive = try #require(try server.patched("/v1/sessions/conv_w").last)
    #expect(archive["archived"] as? Bool == true)
    #expect(archive["delete_worktree"] as? Bool == true)
  }

  @Test("Undo after the worktree went says the worktree is gone")
  func undoAfterTheWorktreeLeft() async throws {
    let server = worktreeServer()
    let (view, session) = try await opened(server)
    let change = SidebarUndo.Change.archive(["conv_w"], true)
    let undone = SidebarUndo(
      change: change, removesWorktrees: true, createdAt: Date(timeIntervalSinceNow: -3600))
    view.sidebarModel.undo = undone
    let banner = try #require(undone.banner)
    view.sidebarActions.undo?(banner)
    try await eventually("the warning") { session.connection.sessionList.editError != nil }
    #expect(session.connection.sessionList.editError?.message.contains("worktree") == true)
  }

}

extension SidebarRowActionsTests {
  @Test("A project's menu creates, moves into, renames, reorders, sorts and deletes")
  func projectMenu() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/projects", method: "POST", .json(#"{"id":"p2","name":"Beta"}"#, status: 201))
    server.route("/v1/projects/p1", method: "PATCH", .json(#"{"id":"p1","name":"Renamed"}"#))
    server.route("/v1/projects/p1", method: "DELETE", .json(#"{"deleted":true}"#))
    server.route("/v1/projects/order", method: "PUT", .json("{}"))
    let (view, session) = try await opened(server)
    let actions = view.sidebarActions

    actions.createProject?("Beta", nil, try summary(session))
    try await eventually("the new project") { !server.requests("POST", "/v1/projects").isEmpty }
    try await eventually("the session filed") {
      (try? server.patched("/v1/sessions/conv_a").last?["project_id"] as? String) == "p2"
    }
    actions.createProject?("Gamma", nil, nil)
    try await eventually("another") { server.requests("POST", "/v1/projects").count == 2 }

    actions.renameProject?(project, "Renamed", nil)
    try await eventually("the rename") { !server.requests("PATCH", "/v1/projects/p1").isEmpty }
    actions.reorderProjects?([project])
    try await eventually("the order") { !server.requests("PUT", "/v1/projects/order").isEmpty }
    actions.setProjectSort?(.manual)
    actions.setProjectSort?(.alphabetical)
    actions.deleteProject?(project)
    try await eventually("the delete") { !server.requests("DELETE", "/v1/projects/p1").isEmpty }
  }

  @Test("A project's next page is read for that project")
  func aProjectsNextPage() async throws {
    let server = threeSessionServer()
    let (view, _) = try await opened(server)
    let before = server.requests("GET", "/v1/sessions").count
    view.sidebarActions.loadProjectPage?(project)
    try await eventually("the page") { server.requests("GET", "/v1/sessions").count > before }
  }

  @Test("Project settings opens, Cancel closes it, Save writes and rereads the projects")
  func projectSettings() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/projects/p1", .json(#"{"id":"p1","name":"Alpha","config":{"workspace":"/alpha"}}"#))
    let (view, _) = try await opened(server)
    view.sidebarActions.openProjectSettings?(project)
    let flow = try #require(view.sidebarModel.projectSettings)
    let screen = OffscreenWindow(
      Color.clear.sheet(isPresented: .constant(true)) { view.projectSettingsSheet(flow) },
      width: 700, height: 700)
    defer { screen.close() }
    try await pause(screen, .milliseconds(150))
    try pressShortcut(screen, keyCode: 53, characters: "\u{1b}", modifiers: [])
    #expect(view.sidebarModel.projectSettings == nil, "Cancel closes it")

    view.sidebarActions.openProjectSettings?(project)
    let next = try #require(view.sidebarModel.projectSettings)
    let saving = OffscreenWindow(
      Color.clear.sheet(isPresented: .constant(true)) { view.projectSettingsSheet(next) },
      width: 700, height: 700)
    defer { saving.close() }
    try await pause(saving, .milliseconds(150))
    let before = server.requests("GET", "/v1/sessions/projects").count
    try pressShortcut(saving, keyCode: 36, characters: "\r", modifiers: [])
    try await settle(saving, until: "the sheet to close") {
      view.sidebarModel.projectSettings == nil
    }
    #expect(server.requests("GET", "/v1/sessions/projects").count > before)
    #expect(!server.requests("PATCH", "/v1/projects/p1").isEmpty)
  }

  @Test("Share shows where the server shares, says why where it stopped, and opens its sheet")
  func sharing() async throws {
    let server = threeSessionServer()
    let (view, session) = try await opened(server)
    #expect(view.shareAction == nil, "a single-user server has no Share")
    server.route("/v1/info", .json(#"{"single_user":false,"sharing_mode":"off"}"#))
    _ = await session.connection.pages?.loadOffered()
    #expect(view.shareUnavailableReason?.contains("disabled") == true)

    server.route("/v1/info", .json(#"{"single_user":false,"sharing_mode":"enabled"}"#))
    _ = await session.connection.pages?.loadOffered()
    let share = try #require(view.shareAction)
    share(try summary(session))
    #expect(view.sidebarSharePresented.wrappedValue)
    let screen = OffscreenWindow(view.sidebarShareSheet, width: 500, height: 500)
    defer { screen.close() }
    try await settle(screen, untilShowing: "Restricted")
    view.sidebarSharePresented.wrappedValue = false
    #expect(view.sidebarModel.share == nil)
  }

  @Test("Fork from a row says why it can't, or opens the sheet; Cancel closes it")
  func forkFromARow() async throws {
    let server = worktreeServer()
    let (view, session) = try await opened(server)
    view.beginSidebarFork("gone")
    #expect(!view.sidebarForkPresented.wrappedValue)

    view.sessionListActions.fork?(try summary(session, "conv_w"))
    try await eventually("the sheet") { view.sidebarForkPresented.wrappedValue }
    let actions = view.sidebarForkActions
    actions.selectionChanged?("ag_claude", "mac")
    actions.cancel()
    #expect(!view.sidebarForkPresented.wrappedValue)
  }

  @Test("Fork from a row creates it and opens its chat; one with no agent says why")
  func forkOpensTheChat() async throws {
    let server = worktreeServer()
    server.route(
      "/v1/sessions/conv_w/fork", method: "POST",
      .json(#"{"id":"conv_f","status":"idle","created_at":5,"permission_level":4}"#, status: 201))
    let (view, session) = try await opened(server)
    view.beginSidebarFork("conv_w")
    try await eventually("the sheet") { view.sidebarForkPresented.wrappedValue }
    view.sidebarForkActions.forkWith(
      ForkChoices(agentID: "ag_claude", directory: "/wt", start: false, hostID: "mac"))
    try await eventually("the fork's tab") { session.tabs.groups["conv_f"] != nil }

    let plain = threeSessionServer()
    let (other, otherSession) = try await opened(plain)
    other.beginSidebarFork("conv_a")
    #expect(
      otherSession.connection.sessionList.editError?.message == "This session has no agent to fork."
    )
  }
}
