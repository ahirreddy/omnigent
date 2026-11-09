import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import Testing

@testable import OmnigentAppUI

/// What a server with every settings page says about itself. Read after connecting, since the
/// default fake is a local server and these accounts would change how it signs in.
let everyPageInfo =
  #"{"single_user":false,"accounts_enabled":true,"login_url":"/auth/login","enabled_connections":["mcp","github"],"archive_worktree_cleanup":true}"#

/// A server with every settings page on it, as an administrator.
func settingsServer() -> AppServer {
  let server = AppServer()
  server.route(
    "/auth/users",
    .json(#"{"users":[{"id":"bob@example.com","is_admin":false,"created_at":1700000000.5}]}"#))
  server.route("/auth/users/bob@example.com", method: "DELETE", .json("{}"))
  server.route(
    "/auth/users/bob@example.com/reset", method: "POST",
    .json(#"{"id":"bob@example.com","new_password":"fresh"}"#))
  server.route("/auth/users/me/password", method: "POST", .json("{}"))
  server.route(
    "/v1/policies", method: "GET",
    .json(#"{"object":"list","data":[{"id":"p1","name":"Ask","handler":"a.b","enabled":true}]}"#))
  server.route(
    "/v1/policies/p1", method: "PATCH",
    .json(#"{"id":"p1","name":"Ask","handler":"a.b","enabled":false}"#))
  server.route("/v1/policies/p1", method: "DELETE", .json("{}"))
  server.route(
    "/v1/policies", method: "POST",
    .json(#"{"id":"p2","name":"New","handler":"a.b","enabled":true}"#))
  server.route(
    "/v1/policy-registry",
    .json(
      #"{"object":"list","data":[{"handler":"a.b","kind":"factory","name":"Ask","description":"Asks","params_schema":{"type":"object","properties":{}}}]}"#
    ))
  routeServicesAndArchive(server)
  return server
}

/// Sharing, MCP, integrations, import and archived sessions.
private func routeServicesAndArchive(_ server: AppServer) {
  let sharing =
    #"{"object":"sharing","sharing_mode":"on","editable":true,"options":["on","off"],"public_sharing_enabled":false,"public_sharing_editable":true,"default_public_sessions":"off","default_public_sessions_editable":true,"default_public_sessions_options":["off","all"]}"#
  server.route("/v1/sharing", method: "GET", .json(sharing))
  server.route("/v1/sharing", method: "PUT", .json(sharing))
  server.route(
    "/v1/mcp-registry/services",
    .json(
      #"{"data":[{"id":"docs","title":"Docs","auth":"bearer","connected":false},{"id":"empty","title":"Empty","auth":"bearer","connected":true},{"id":"bad","title":"Bad","auth":"bearer","connected":true}],"has_more":false}"#
    ))
  server.route(
    "/v1/mcp-registry/services/docs/connection", method: "PUT", .json(#"{"connected":true}"#))
  server.route(
    "/v1/mcp-registry/services/docs/connection", method: "DELETE", .json(#"{"connected":false}"#))
  server.route(
    "/v1/mcp-registry/services/docs/test", method: "POST", .json(#"{"tools":["read","write"]}"#))
  server.route("/v1/mcp-registry/services/empty/test", method: "POST", .json(#"{"tools":[]}"#))
  server.route(
    "/v1/mcp-registry/services/bad/test", method: "POST", .json(#"{"detail":"no"}"#, status: 500))
  server.route(
    "/v1/connections/github/status", .json(#"{"enabled":true,"connected":true,"login":"octocat"}"#))
  server.route("/v1/connections/github/disconnect", method: "POST", .json("{}"))
  server.route(
    "/v1/hosts", .json(#"{"hosts":[{"host_id":"h1","name":"Mac","status":"online"}]}"#))
  server.route(
    "/v1/imports/local", method: "POST",
    .json(#"{"imported":2,"already_imported":1,"failed":0,"sessions":[]}"#))
  server.route(
    "/v1/sessions",
    .json(
      #"{"object":"list","data":[\#(sessionRow("conv_old", host: "h1", workspace: "/w", updatedAt: 5, archived: true))],"has_more":false}"#
    ))
  server.route("/v1/sessions/conv_old", method: "DELETE", .json("{}"))
  server.route("/v1/sessions/conv_old", method: "PATCH", .json("{}"))
  server.route(
    "/v1/sessions/conv_old", method: "GET",
    .json(sessionRow("conv_old", host: "h1", workspace: "/w", updatedAt: 5, archived: true)))
}

/// Each control in a server's settings reaches the server.
@MainActor
@Suite("Server settings wiring", .timeLimit(.minutes(1)))
struct ServerSettingsWiringTests {
  private final class Calls {
    var web: [ServerSettingsPane] = []
    var signedOut = 0
    var opened: [String] = []
  }

  private func wired(_ server: AppServer = settingsServer(), info: String = everyPageInfo)
    async throws -> (ServerSettingsWiring, Calls)
  {
    let connection = try await signedInStore(server)
    server.route("/v1/info", .json(info))
    server.route("/v1/me", .json(#"{"user_id":"ada","is_admin":true}"#))
    let store = try #require(connection.serverSettings())
    let calls = Calls()
    let wiring = ServerSettingsWiring(
      store: store, connection: connection, openSession: { calls.opened.append($0) },
      openWebSettings: { calls.web.append($0) }, signOut: { _ in calls.signedOut += 1 })
    await store.loadInfo()
    return (wiring, calls)
  }

  private func state(_ wiring: ServerSettingsWiring) -> ServerSettingsViewState {
    ServerSettingsAdapter.state(wiring.store, servers: [])
  }

  @Test("Each pane reads what it shows")
  func panesLoad() async throws {
    let (wiring, _) = try await wired()
    let actions = wiring.actions()
    for pane in ServerSettingsPane.allCases { actions.load?(pane) }
    try await eventually("every pane") {
      let store = wiring.store
      return store.mcpServices.value != nil && store.connections.value != nil
        && store.importHosts.value != nil && store.members.value != nil
        && store.policies.value != nil && store.policyRegistry.value != nil
        && store.sharing.value != nil && store.archived.value != nil
    }
    let shown = state(wiring)
    #expect(shown.errorMessage == nil)
    #expect(shown.mcpServices.map(\.id) == ["docs", "empty", "bad"])
    #expect(shown.members.map(\.id) == ["bob@example.com"])
    #expect(shown.policies.map(\.id) == ["p1"])
    #expect(shown.connections.first?.id == "github")
    #expect(shown.importHosts.map(\.id) == ["h1"])
    #expect(shown.sharing?.mode == "on")
    #expect(shown.archived.map(\.id) == ["conv_old"])
  }

  @Test("A pane opened before the server's info reads it first")
  func aPaneReadsTheInfoFirst() async throws {
    let server = settingsServer()
    let connection = try await signedInStore(server)
    server.route("/v1/info", .json(everyPageInfo))
    server.route("/v1/me", .json(#"{"user_id":"ada","is_admin":true}"#))
    let store = try #require(connection.serverSettings())
    let wiring = ServerSettingsWiring(
      store: store, connection: connection, openSession: nil, openWebSettings: { _ in },
      signOut: { _ in })
    wiring.actions().loadServer?()
    try await eventually("the info") { store.info.value != nil }
    let before = server.requests("GET", "/v1/info").count
    wiring.actions().loadServer?()
    await wiring.load(.git)
    #expect(server.requests("GET", "/v1/info").count == before, "it isn't read twice")
  }

  @Test("MCP: connect sends the token, test reports its tools, disconnect removes it")
  func mcpControls() async throws {
    let server = settingsServer()
    let (wiring, calls) = try await wired(server)
    await wiring.load(.mcp)
    let actions = wiring.actions()
    let rows = state(wiring).mcpServices
    let docs = try #require(rows.first { $0.id == "docs" })
    #expect(await actions.connectMCP?(docs, "secret") == true)
    #expect(server.requests("PUT", "/v1/mcp-registry/services/docs/connection").count == 1)
    #expect(await actions.testMCP?(docs) == "Tools: read, write")
    let empty = try #require(rows.first { $0.id == "empty" })
    #expect(await actions.testMCP?(empty) == "Connected; no tools listed.")
    let bad = try #require(rows.first { $0.id == "bad" })
    #expect(await actions.testMCP?(bad)?.hasPrefix("Test failed: ") == true)
    actions.disconnectMCP?(docs)
    try await eventually("the disconnect") {
      !server.requests("DELETE", "/v1/mcp-registry/services/docs/connection").isEmpty
    }
    actions.openInBrowser?(.mcp)
    #expect(calls.web == [.mcp])
  }

  @Test("Integrations: disconnect names the provider")
  func disconnectProvider() async throws {
    let server = settingsServer()
    let (wiring, _) = try await wired(server)
    await wiring.load(.integrations)
    let row = try #require(state(wiring).connections.first)
    wiring.actions().disconnectProvider?(row)
    try await eventually("the disconnect") {
      !server.requests("POST", "/v1/connections/github/disconnect").isEmpty
    }
  }

  @Test("Import sends the host, the source and the limit, and shows the tally")
  func importing() async throws {
    let server = settingsServer()
    let (wiring, _) = try await wired(server)
    let summary = await wiring.actions().importSessions?("h1", "claude", 5, nil)
    #expect(summary?.contains("2") == true)
    let body = try #require(try server.posted("/v1/imports/local").first)
    #expect(body["host_id"] as? String == "h1")
    #expect(body["limit"] as? Int == 5)
  }

  @Test("Account: a password change goes through; sign out appears for a login session")
  func account() async throws {
    let server = settingsServer()
    let (wiring, calls) = try await wired(server)
    let actions = wiring.actions()
    #expect(await actions.changePassword?("old-password", "new-password-1") == true)
    #expect(server.requests("POST", "/auth/users/me/password").count == 1)
    let signOut = try #require(actions.signOut, "this server has a login session")
    signOut()
    #expect(calls.signedOut == 1)
    actions.openSession?("conv_old")
    #expect(calls.opened == ["conv_old"])
  }

  @Test("Members: reset gives the new password, remove reaches the server, invite needs accounts")
  func members() async throws {
    let server = settingsServer()
    server.route(
      "/auth/invite", method: "POST",
      .json(
        #"{"token":"tok","register_url":"http://x/register?invite=tok","expires_at":1700000000,"is_admin":true}"#
      ))
    let (wiring, _) = try await wired(server)
    await wiring.load(.members)
    let actions = wiring.actions()
    let bob = try #require(state(wiring).members.first)
    #expect(await actions.resetPassword?(bob) == "fresh")
    actions.removeMember?(bob)
    try await eventually("the removal") {
      !server.requests("DELETE", "/auth/users/bob@example.com").isEmpty
    }
    let invite = await actions.invite?(true)
    #expect(server.requests("POST", "/auth/invite").count == 1)
    #expect(invite != nil)
  }

  @Test("Invites are only offered where accounts are on")
  func noInviteWithoutAccounts() async throws {
    let (wiring, _) = try await wired(info: #"{"single_user":true,"accounts_enabled":false}"#)
    #expect(wiring.actions().invite == nil)
    #expect(wiring.actions().signOut == nil, "no login session to end")
  }

  @Test("Policies: add from the registry, toggle and delete")
  func policies() async throws {
    let server = settingsServer()
    let (wiring, _) = try await wired(server)
    await wiring.load(.policies)
    let actions = wiring.actions()
    let entry = try #require(wiring.store.policyRegistry.value?.first)
    let template = ServerSettingsAdapter.policyTemplate(entry)
    #expect(await actions.addPolicy?(template, "New", [:]) == true)
    #expect(try server.posted("/v1/policies").first?["name"] as? String == "New")
    let unknown = PolicyTemplate(
      id: "gone", name: "Gone", detail: "", suggestedName: "", params: [])
    #expect(await actions.addPolicy?(unknown, "x", [:]) == false, "not in the registry any more")
    let row = try #require(state(wiring).policies.first)
    actions.setPolicyEnabled?(row, false)
    try await eventually("the toggle") { !server.requests("PATCH", "/v1/policies/p1").isEmpty }
    #expect(try server.patched("/v1/policies/p1").first?["enabled"] as? Bool == false)
    actions.deletePolicy?(row)
    try await eventually("the delete") { !server.requests("DELETE", "/v1/policies/p1").isEmpty }
  }

  @Test("Sharing sends only what changed; archived sessions unarchive and delete")
  func sharingAndArchived() async throws {
    let server = settingsServer()
    let (wiring, _) = try await wired(server)
    await wiring.load(.sharing)
    await wiring.load(.archived)
    let actions = wiring.actions()
    actions.changeSharing?(.publicSharing(true))
    try await eventually("the sharing change") { !server.requests("PUT", "/v1/sharing").isEmpty }
    actions.unarchive?(["conv_old"])
    try await eventually("the unarchive") {
      !server.requests("PATCH", "/v1/sessions/conv_old").isEmpty
    }
    actions.loadMoreArchived?()
    actions.delete?(["conv_old"])
    try await eventually("the delete") {
      !server.requests("DELETE", "/v1/sessions/conv_old").isEmpty
    }
  }
}
