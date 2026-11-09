import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import OmnigentWorkspaceUI
import SwiftUI
import Testing

@testable import OmnigentAppUI

/// The Canvas page through its window, and the smaller hosts the app shows beside it.
@MainActor
@Suite("Canvas page", .serialized, .timeLimit(.minutes(1)))
struct CanvasScreenTests {
  private final class Calls {
    var opened: [String] = []
    var newSessions = 0
  }

  private struct OpenPage {
    let screen: OffscreenWindow<CanvasAdapter>
    let calls: Calls
    let connection: ConnectionStore
  }

  private func page(
    _ server: AppServer = threeSessionServer(), projects: String = "[]"
  ) async throws -> OpenPage {
    SystemSideEffects.install()
    server.route("/v1/sessions/projects", .json(projects))
    let connection = try await signedInStore(server)
    server.route("/v1/info", .json(#"{"single_user":true,"features":{"canvas":true}}"#))
    _ = await connection.pages?.loadOffered()
    try await eventually("the list") { connection.sessionList.isLoaded }
    let calls = Calls()
    let adapter = CanvasAdapter(
      connection: connection, open: { calls.opened.append($0) },
      newSession: { calls.newSessions += 1 })
    let screen = OffscreenWindow(adapter, width: 1000, height: 700)
    return OpenPage(screen: screen, calls: calls, connection: connection)
  }

  private func forgetLayout(_ connection: ConnectionStore) {
    let server = connection.connectedServer
    let prefix = "omnigent.canvas.\(server?.baseUrl ?? "").\(server?.userId ?? "")"
    for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(prefix) {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }

  @Test("Enabled, it lays the sessions out; New session and a card's click leave the page")
  func thePage() async throws {
    let opened = try await page()
    let (screen, calls, connection) = (opened.screen, opened.calls, opened.connection)
    defer {
      forgetLayout(connection)
      screen.close()
    }
    try await settle(screen, untilShowing: "3 sessions")
    #expect(try screen.shows("Main"))
    let canvas = try #require(connection.canvas)
    let actions = CanvasAdapter(
      connection: connection, open: { calls.opened.append($0) },
      newSession: { calls.newSessions += 1 }
    ).actions(canvas)
    actions.open?("conv_a")
    actions.newSession?()
    #expect(calls.opened == ["conv_a"])
    #expect(calls.newSessions == 1)

    actions.move?("conv_a", 1234, 5678)
    let moved = snapCanvasPosition(x: 1234, y: 5678)
    #expect(canvas.positions["conv_a"] == moved, "a moved card keeps its place")
    actions.resetLayout?()
    #expect(canvas.positions["conv_a"] != moved)
  }

  @Test("Projects are boards: choosing one shows its sessions and says when it has none")
  func boards() async throws {
    let opened = try await page(projects: #"[{"id":"p1","name":"Alpha"}]"#)
    let (screen, connection) = (opened.screen, opened.connection)
    defer {
      forgetLayout(connection)
      screen.close()
    }
    try await settle(screen, untilShowing: "Alpha")
    let canvas = try #require(connection.canvas)
    let state = CanvasMapping.state(canvas, list: connection.sessionList)
    #expect(state.boards.map(\.name) == ["Main", "Alpha"])
    #expect(state.emptyTitle == "No sessions outside projects" || !state.cards.isEmpty)
    let alpha = try #require(state.boards.last)
    canvas.select(board: alpha.id)
    try await settle(screen, untilShowing: "No sessions in Alpha")
    canvas.select(board: CanvasMapping.mainBoardID)
  }

  @Test("A page that can't load says why, and Retry reads again")
  func aFailedLoad() async throws {
    let server = threeSessionServer()
    server.route("/v1/sessions", method: "GET", .json(#"{"detail":"down"}"#, status: 500))
    SystemSideEffects.install()
    let connection = try await signedInStore(server)
    let canvas = try #require(connection.canvas)
    await canvas.load(viewerID: nil)
    let failed = CanvasMapping.state(canvas, list: connection.sessionList)
    #expect(failed.loadError?.isEmpty == false)
    server.route(
      "/v1/sessions", method: "GET",
      .json(
        #"{"object":"list","data":[\#(sessionRow("conv_a", host: "mac", workspace: " ", updatedAt: 3))],"has_more":false}"#
      ))
    let adapter = CanvasAdapter(connection: connection, open: { _ in }, newSession: {})
    adapter.actions(canvas).retry?()
    try await eventually("the retry") { canvas.sessions.value != nil }
    canvas.relayout(projects: [], viewerID: nil)
    let loaded = CanvasMapping.state(canvas, list: connection.sessionList)
    #expect(loaded.cards.first?.workspace == "No working directory")

    server.route("/v1/sessions", method: "GET", .json(#"{"detail":"down"}"#, status: 500))
    await canvas.load(viewerID: nil)
    #expect(
      CanvasMapping.state(canvas, list: connection.sessionList).refreshError?.isEmpty == false)
  }

  @Test("The Agents panel reads the tree, opens a node, and Refresh reads again")
  func theAgentsPanel() async throws {
    let store = try await ConversationFixtures.store(
      sections: [
        ConversationFixtures.section("child-1", details: [("state", "running")]),
        ConversationFixtures.section("other"),
      ])
    #expect(AgentTreeAdapter.childSignature(store) == ["child-1:running"])
    final class Opened { var ids: [String] = [] }
    let opened = Opened()
    let screen = OffscreenWindow(
      AgentTreePanelHost(conversation: store, open: { opened.ids.append($0) }), width: 400,
      height: 400)
    defer { screen.close() }
    try await settle(screen, until: "the read to end") { store.tools.agentTreeError != nil }
    let state = AgentTreeAdapter.state(store.tools)
    #expect(state.errorMessage?.isEmpty == false)
    #expect(state.nodes.isEmpty)
    #expect(!state.isLoading)
    #expect(state.currentID == store.sessionID)
  }

  @Test("Reveal and Open act on a folder this Mac has; another machine's has neither")
  func revealAndOpen() throws {
    SystemSideEffects.install()
    SystemSideEffects.reset()
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      do {
        try FileManager.default.removeItem(at: folder)
      } catch {
        Issue.record("could not remove the test folder: \(error)")
      }
    }
    #expect(WorkspaceActionsAdapter.isLocalFolder(folder.path))
    #expect(!WorkspaceActionsAdapter.isLocalFolder(folder.appending(path: "nope").path))

    let source = EndlessDirectory()
    source.root = folder.path
    let workspace = WorkspaceBrowserModel(source: source)
    let local = WorkspaceActionsAdapter.actions(workspace, mention: nil, report: { _ in })
    local.reveal?("/some/file")
    local.openExternally?("/some/file")
    #expect(SystemSideEffects.record.revealedURLs.map(\.path) == ["/some/file"])
    #expect(SystemSideEffects.record.openedURLs.map(\.path) == ["/some/file"])

    source.root = "/not/on/this/mac"
    let remote = WorkspaceBrowserModel(source: source)
    let none = WorkspaceActionsAdapter.actions(remote, mention: nil, report: { _ in })
    #expect(none.reveal == nil)
    #expect(none.openExternally == nil)
  }
}
