import AppKit
import Foundation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import SwiftUI
import Testing

@testable import OmnigentAppUI

/// The command palette over the connected window's stores.
@MainActor
@Suite("Palette", .timeLimit(.minutes(1)))
struct PaletteAdapterStateTests {
  private func palette(_ session: ServerSession, _ selection: WindowSelection) -> PaletteAdapter {
    PaletteAdapter(session: session, selection: selection.binding)
  }

  @Test("Sessions are newest first and say their state, agent and folder")
  func sessions() async throws {
    let session = try await signedInSession(threeSessionServer())
    let selection = WindowSelection()
    let state = palette(session, selection).state
    #expect(state.sessions.map(\.id) == ["session-conv_a", "session-conv_b", "session-conv_c"])
    #expect(state.sessions.first?.detail.hasPrefix("Ready") == true)
    #expect(state.sessions.first?.detail.hasSuffix("/work/conv_a") == true)
    #expect(state.scope == session.connection.connectedServer?.serverName)
    #expect(!state.hasNextRequest)
    #expect(!state.showsAutomations)
  }

  @Test("A session that waits on the user offers Next Request, which cycles through them")
  func nextRequest() async throws {
    let session = try await connectedDemo()
    try await eventually("waiting sessions") {
      session.connection.sessionList.needsResponse.count == 2
    }
    let selection = WindowSelection()
    let adapter = palette(session, selection)
    #expect(adapter.state.hasNextRequest)
    let ids = session.connection.sessionList.needsResponse.map(\.id)
    adapter.perform(.nextRequest)
    #expect(selection.page == .session(ids[0]))
    adapter.perform(.nextRequest)
    #expect(selection.page == .session(ids[1]))
    adapter.perform(.nextRequest)
    #expect(selection.page == .session(ids[0]), "it wraps around")
    selection.page = .session("demo-notes")
    adapter.perform(.nextRequest)
    #expect(selection.page == .session(ids[0]), "from elsewhere it starts at the first")
  }

  @Test("Pages open by selecting them; the rest leave the selection alone")
  func navigation() async throws {
    let session = try await signedInSession(threeSessionServer())
    let selection = WindowSelection()
    let adapter = palette(session, selection)
    _ = NSApplication.shared
    let pages: [(PaletteTarget, SidebarDestination)] = [
      (.newSession, .newSession), (.inbox, .inbox), (.automations, .automations),
      (.usage, .usage), (.session("conv_b"), .session("conv_b")),
    ]
    for (target, destination) in pages {
      adapter.perform(target)
      #expect(selection.page == destination)
    }
    for target in [PaletteTarget.findSession, .changes, .composer, .settings, .toggleSidebar] {
      adapter.perform(target)
      #expect(selection.page == .session("conv_b"))
    }
    adapter.perform(.nextRequest)
    #expect(selection.page == .session("conv_b"), "nothing waits, so it stays")
  }

  @Test("Choosing a server leaves the window's page and connects there")
  func aServer() async throws {
    let session = try await signedInSession(threeSessionServer())
    let selection = WindowSelection()
    selection.page = .inbox
    palette(session, selection).perform(.server("http://127.0.0.1:7000"))
    #expect(selection.page == nil)
    #expect(session.signIn.state.lastServerUrl == "http://127.0.0.1:7000")
  }

  @Test("Search lists title matches and message matches with their snippet")
  func search() async throws {
    let server = threeSessionServer()
    let session = try await signedInSession(server)
    let adapter = palette(session, WindowSelection())
    let results = await adapter.searchServer("conv", limit: 2)
    #expect(results.failure == nil)
    #expect(results.titles.first?.id.hasPrefix("found-") == true)
    #expect(results.messages.first?.id.hasPrefix("message-") == true)
    #expect(results.hasMore, "the page came back full")
    server.route("/v1/sessions", method: "GET", .json(#"{"detail":"nope"}"#, status: 500))
    let failed = await adapter.searchServer("conv", limit: 2)
    #expect(failed.failure?.isEmpty == false)
  }
}

/// The Share sheet against a server's permissions.
@MainActor
@Suite("Share", .timeLimit(.minutes(1)))
struct ShareAdapterStoreTests {
  private func shared(_ server: AppServer) async throws -> ShareStore {
    let connection = try await signedInStore(server)
    let store = try #require(connection.share(sessionID: "conv_a"))
    await store.load()
    return store
  }

  private func server() -> AppServer {
    let server = AppServer()
    server.route(
      "/v1/sessions/conv_a/permissions", method: "GET",
      .json(
        #"{"permissions":[{"user_id":"local","level":4},{"user_id":"__public__","level":1},{"user_id":"ann","level":1},{"user_id":"ben","level":2}],"next_cursor":null}"#
      ))
    server.route("/v1/sessions/conv_a/permissions", method: "PUT", .json("{}"))
    server.route("/v1/sessions/conv_a/permissions/ann", method: "DELETE", .json("{}"))
    return server
  }

  @Test("People are listed by what they can do; the owner and the public grant aren't")
  func state() async throws {
    let store = try await shared(server())
    let link = URL(string: "http://x/s/1")
    let state = ShareAdapter.state(store, link: link)
    #expect(state.grants.map(\.principal) == ["ann", "ben"])
    #expect(state.grants.map(\.role) == [.read, .edit])
    #expect(state.generalAccess == ShareAdapter.anyoneWithLink)
    #expect(state.link == link)
    #expect(state.errorMessage == nil)
  }

  @Test("Each control reaches the server")
  func actions() async throws {
    let fake = server()
    let store = try await shared(fake)
    let actions = ShareAdapter.actions(store)
    let writes = { fake.requests("PUT", "/v1/sessions/conv_a/permissions").count }
    actions.addGrant?("cam", .edit)
    try await eventually("the grant") { writes() == 1 }
    actions.setRole?(ShareGrant(id: "ann", principal: "ann", role: .read), .edit)
    try await eventually("the role") { writes() == 2 }
    actions.setGeneralAccess?(ShareAdapter.restricted)
    try await eventually("general access") {
      writes() > 2 || !fake.requests("DELETE", "/v1/sessions/conv_a/permissions/__public__").isEmpty
    }
    actions.removeGrant?(ShareGrant(id: "ann", principal: "ann", role: .read))
    try await eventually("the removal") {
      !fake.requests("DELETE", "/v1/sessions/conv_a/permissions/ann").isEmpty
    }
  }

  @Test("A list that can't be read says why")
  func failure() async throws {
    let fake = AppServer()
    fake.route("/v1/sessions/conv_a/permissions", .json(#"{"detail":"no"}"#, status: 500))
    let store = try await shared(fake)
    #expect(ShareAdapter.state(store, link: nil).errorMessage?.isEmpty == false)
  }

  @Test("Share is offered, or disabled with the reason, by what the server says")
  func offered() {
    #expect(!ShareAdapter.offered(nil))
    #expect(ShareAdapter.unavailableReason(nil) == nil)
  }
}

/// One open Project settings sheet.
@MainActor
@Suite("Project settings flow", .timeLimit(.minutes(1)))
struct ProjectSettingsFlowTests {
  private func flow(
    _ server: AppServer
  ) async throws -> ProjectSettingsFlow {
    server.route(
      "/v1/projects/p1", method: "GET",
      .json(
        #"{"id":"p1","name":"Alpha","config":{"host_id":"mac","agent_id":"ag_claude","model":"claude-native-fast","workspace":"/alpha"}}"#
      ))
    let connection = try await signedInStore(server)
    let store = try #require(
      connection.projectSettings(ProjectSummary(id: "p1", name: "Alpha", icon: nil)))
    let flow = ProjectSettingsFlow(store: store, alwaysUseWorktree: false)
    await flow.load()
    return flow
  }

  @Test("Opening fills the fields from what's stored and lists the agent's models")
  func opening() async throws {
    let flow = try await flow(newSessionServer())
    #expect(flow.draftBinding.wrappedValue.workspace == "/alpha")
    #expect(flow.draftBinding.wrappedValue.agentID == "ag_claude")
    #expect(flow.state.projectName == "Alpha")
    #expect(flow.store.models.value?.isEmpty == false)
  }

  @Test("Another agent clears the model and effort and reads its own models")
  func anotherAgent() async throws {
    let server = newSessionServer()
    let flow = try await flow(server)
    let reads = server.requests("GET", "/v1/hosts/mac/harnesses/codex-native/model-options").count
    var draft = flow.draftBinding.wrappedValue
    draft.agentID = "ag_codex"
    flow.draftBinding.wrappedValue = draft
    #expect(flow.draftBinding.wrappedValue.model == nil)
    try await eventually("the models") {
      server.requests("GET", "/v1/hosts/mac/harnesses/codex-native/model-options").count > reads
    }
    let same = flow.draftBinding.wrappedValue
    flow.draftBinding.wrappedValue = same
    #expect(flow.draftBinding.wrappedValue == same)
  }

  @Test("Another folder saves; a refused save says why")
  func saving() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/projects/p1", method: "PATCH",
      .json(#"{"id":"p1","name":"Alpha","config":{"workspace":"/beta"}}"#))
    let flow = try await flow(server)
    var draft = flow.draftBinding.wrappedValue
    draft.workspace = "/beta"
    flow.draftBinding.wrappedValue = draft
    #expect(await flow.save())
    #expect(flow.state.saveError == nil)
    let body = try #require(try server.patched("/v1/projects/p1").first)
    #expect((body["config"] as? [String: Any])?["workspace"] as? String == "/beta")

    server.route("/v1/projects/p1", method: "PATCH", .json(#"{"detail":"no"}"#, status: 500))
    #expect(await !flow.save())
    #expect(flow.state.saveError?.isEmpty == false)
  }
}
