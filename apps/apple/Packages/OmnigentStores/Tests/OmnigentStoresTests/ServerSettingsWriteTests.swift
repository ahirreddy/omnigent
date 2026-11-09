import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// Every Settings pane: what shows after a read, a write and a refusal.
@MainActor
@Suite("Server settings", .timeLimit(.minutes(1)))
struct ServerSettingsWriteTests {
  private func settings(_ server: RouteServer) async throws -> ServerSettingsStore {
    try #require(try await connectedStore(server).serverSettings())
  }

  private func failed<Value>(_ load: CreationLoad<Value>) -> Bool {
    if case .failed = load { return true }
    return false
  }

  @Test("A refused read shows as that pane's failure and a later read recovers it")
  func readsFailAndRecover() async throws {
    let server = RouteServer()
    server.fail("/v1/sessions", method: "GET")
    let settings = try await settings(server)
    await settings.loadMembers()
    await settings.loadPolicies()
    await settings.loadPolicyRegistry()
    await settings.loadSharing()
    await settings.loadMCPServices()
    await settings.loadConnections(["github"])
    await settings.loadImportHosts()
    await settings.loadArchived()
    #expect(failed(settings.members))
    #expect(failed(settings.policies))
    #expect(failed(settings.policyRegistry))
    #expect(failed(settings.sharing))
    #expect(failed(settings.mcpServices))
    #expect(failed(settings.connections))
    #expect(failed(settings.importHosts))
    #expect(failed(settings.archived))

    server.route("/v1/policy-registry", .json(#"{"object":"list","data":[]}"#))
    await settings.loadPolicyRegistry()
    #expect(settings.policyRegistry.value?.isEmpty == true)
  }

  @Test("The policy registry is read once")
  func registryCached() async throws {
    let server = RouteServer()
    server.route("/v1/policy-registry", .json(#"{"object":"list","data":[]}"#))
    let settings = try await settings(server)
    await settings.loadPolicyRegistry()
    await settings.loadPolicyRegistry()
    #expect(server.requests(to: "/v1/policy-registry").count == 1)
  }

  @Test("Removing a member reloads the list; a refusal keeps the row and says why")
  func members() async throws {
    let server = RouteServer()
    server.route(
      "/auth/users", method: "GET",
      .json(#"{"users":[{"id":"ada","is_admin":true,"created_at":1,"has_password":true}]}"#))
    server.fail("/auth/users/ada", method: "DELETE", status: 403, detail: "no")
    let settings = try await settings(server)
    await settings.loadMembers()
    #expect(settings.members.value?.map(\.id) == ["ada"])

    await settings.removeMember("ada")
    #expect(settings.error != nil)
    #expect(settings.members.value?.map(\.id) == ["ada"])
    #expect(server.requests(to: "/auth/users", method: "GET").count == 1)

    server.route("/auth/users/ada", method: "DELETE", .json("", status: 204))
    server.route("/auth/users", method: "GET", .json(#"{"users":[]}"#))
    await settings.removeMember("ada")
    #expect(settings.error == nil, "the next write clears the last failure")
    #expect(settings.members.value?.isEmpty == true)
    #expect(!settings.isSaving)
  }

  @Test("A new password and an invite show once, and a refusal gives neither")
  func oneTimeSecrets() async throws {
    let server = RouteServer()
    let settings = try await settings(server)
    #expect(await settings.resetPassword("ada") == nil)
    #expect(settings.error != nil)
    #expect(await settings.invite(isAdmin: false) == nil)

    server.route("/auth/users/ada/reset", .json(#"{"id":"ada","new_password":"fresh"}"#))
    #expect(await settings.resetPassword("ada") == "fresh")
    server.route(
      "/auth/invite",
      .json(#"{"token":"tok","register_url":"http://x/register?invite=tok","is_admin":true}"#))
    let invite = await settings.invite(isAdmin: true)
    #expect(invite?.isAdmin == true)
    #expect(settings.error == nil)
  }

  @Test("Adding and deleting a policy reload only when the server agreed")
  func policies() async throws {
    let server = RouteServer()
    server.route(
      "/v1/policy-registry",
      .json(
        #"{"object":"list","data":[{"handler":"p.os","kind":"callable","name":"Ask","description":"","params_schema":null}]}"#
      ))
    let list =
      #"{"object":"list","data":[{"id":"p1","name":"Ask","handler":"p.os","enabled":true}]}"#
    server.route("/v1/policies", method: "GET", .json(list))
    server.fail("/v1/policies", method: "POST")
    server.fail("/v1/policies/p1", method: "DELETE")
    server.fail("/v1/policies/p1", method: "PATCH")
    let settings = try await settings(server)
    await settings.loadPolicies()
    await settings.loadPolicyRegistry()
    let entry = try #require(settings.policyRegistry.value?.first)
    let reads = { server.requests(to: "/v1/policies", method: "GET").count }

    #expect(await !settings.addPolicy(entry, name: "Ask", values: [:]))
    #expect(settings.error != nil)
    #expect(reads() == 1)

    await settings.deletePolicy("p1")
    #expect(settings.error != nil)
    #expect(settings.policies.value?.count == 1)
    #expect(reads() == 1)

    await settings.setPolicyEnabled("p1", false)
    #expect(settings.policies.value?.first?.enabled == true, "a refused toggle doesn't flip")

    server.route(
      "/v1/policies", method: "POST",
      .json(#"{"id":"p2","name":"Ask","handler":"p.os","enabled":true}"#))
    #expect(await settings.addPolicy(entry, name: "Ask", values: [:]))
    #expect(reads() == 2)

    server.route("/v1/policies/p1", method: "DELETE", .json("", status: 204))
    server.route("/v1/policies", method: "GET", .json(#"{"object":"list","data":[]}"#))
    await settings.deletePolicy("p1")
    #expect(settings.policies.value?.isEmpty == true)
  }

  @Test("Sharing shows the server's answer, and a refusal leaves what was shown")
  func sharing() async throws {
    let server = RouteServer()
    let state = { (mode: String) -> HttpResponse in
      .json(
        #"{"object":"sharing","sharing_mode":"\#(mode)","editable":true,"options":["on","off"],"public_sharing_enabled":false,"public_sharing_editable":true,"default_public_sessions":"off","default_public_sessions_editable":false,"default_public_sessions_options":["off"]}"#
      )
    }
    server.route("/v1/sharing", method: "GET", state("on"))
    server.fail("/v1/sharing", method: "PUT")
    let settings = try await settings(server)
    await settings.loadSharing()
    let update = SharingUpdateRecord(mode: "off", publicSharing: nil, defaultPublicSessions: nil)
    await settings.updateSharing(update)
    #expect(settings.error != nil)
    #expect(settings.sharing.value?.mode == "on")

    server.route("/v1/sharing", method: "PUT", state("off"))
    await settings.updateSharing(update)
    #expect(settings.error == nil)
    #expect(settings.sharing.value?.mode == "off")
  }

  @Test("MCP connect, disconnect and test report what the server said")
  func mcpServices() async throws {
    let server = RouteServer()
    server.route(
      "/v1/mcp-registry/services",
      .json(
        #"{"data":[{"id":"docs","title":"Docs","auth":"bearer","connected":false}],"next_cursor":null}"#
      ))
    let settings = try await settings(server)
    let reads = { server.requests(to: "/v1/mcp-registry/services").count }

    #expect(await !settings.connectMCPService("docs", token: "secret"))
    #expect(settings.error != nil)
    await settings.disconnectMCPService("docs")
    #expect(reads() == 0)
    await #expect(throws: CoreError.self) { try await settings.testMCPService("docs") }

    let connection = "/v1/mcp-registry/services/docs/connection"
    server.route(connection, method: "POST", .json(#"{"connected":true}"#))
    server.route(connection, method: "PUT", .json(#"{"connected":true}"#))
    server.route(connection, method: "DELETE", .json("", status: 204))
    server.route("/v1/mcp-registry/services/docs/test", .json(#"{"tools":["read"]}"#))
    #expect(await settings.connectMCPService("docs", token: "secret"))
    #expect(reads() == 1)
    await settings.disconnectMCPService("docs")
    #expect(reads() == 2)
    #expect(try await settings.testMCPService("docs") == ["read"])
  }

  @Test("Disconnecting a provider rereads the connections; a refusal doesn't")
  func providers() async throws {
    let server = RouteServer()
    let status = "/v1/connections/github/status"
    server.route(status, .json(#"{"enabled":true,"connected":true,"login":"octocat"}"#))
    let settings = try await settings(server)
    await settings.disconnectProvider("github")
    #expect(settings.error != nil)
    #expect(server.requests(to: status).isEmpty)

    await settings.loadConnections(["github"])
    #expect(settings.connections.value?.first?.account == "octocat")
    server.route("/v1/connections/github/disconnect", method: "POST", .json("{}"))
    server.route(status, .json(#"{"enabled":true,"connected":false}"#))
    await settings.disconnectProvider("github")
    #expect(settings.error == nil)
    #expect(settings.connections.value?.first?.connected == false)
  }

  @Test("Importing returns the tally, or nil with the failure")
  func imports() async throws {
    let server = RouteServer()
    server.route(
      "/v1/hosts", .json(#"{"hosts":[{"host_id":"h1","name":"alpha","status":"online"}]}"#))
    let settings = try await settings(server)
    await settings.loadImportHosts()
    #expect(settings.importHosts.value?.count == 1)

    #expect(await settings.importSessions(hostID: "h1", source: "codex", limit: 5) == nil)
    #expect(settings.error != nil)

    server.route(
      "/v1/imports/local", .json(#"{"imported":2,"already_imported":1,"failed":0}"#))
    let tally = await settings.importSessions(
      hostID: "h1", source: "claude", limit: 5, sessionID: "s1")
    #expect(tally?.imported == 2)
    #expect(settings.error == nil)
  }
}

/// The Archived pane: its pages and bulk actions.
@MainActor
@Suite("Archived sessions", .timeLimit(.minutes(1)))
struct ArchivedSessionsPaneTests {
  private func settings(_ server: RouteServer) async throws -> ServerSettingsStore {
    try #require(try await connectedStore(server).serverSettings())
  }

  private func archivedRow(_ id: String) -> String {
    #"{"id":"\#(id)","title":"\#(id)","status":"idle","created_at":1,"updated_at":2,"archived":true}"#
  }

  private func archivedPage(_ ids: [String], hasMore: Bool) -> HttpResponse {
    let rows = ids.map(archivedRow).joined(separator: ",")
    let more = hasMore ? "true" : "false"
    return .json(
      #"{"object":"list","data":[\#(rows)],"has_more":\#(more),"last_id":"\#(ids.last ?? "")"}"#)
  }

  @Test("Archived pages append without repeats, and the last page ends paging")
  func archivedPaging() async throws {
    let server = RouteServer()
    server.route("/v1/sessions", archivedPage(["a1", "a2"], hasMore: true))
    let settings = try await settings(server)
    await settings.loadArchived()
    #expect(settings.archived.value?.map(\.id) == ["a1", "a2"])
    #expect(settings.hasMoreArchived)

    server.route("/v1/sessions", archivedPage(["a2", "a3"], hasMore: false))
    await settings.loadMoreArchived()
    #expect(settings.archived.value?.map(\.id) == ["a1", "a2", "a3"])
    #expect(!settings.hasMoreArchived)

    let reads = server.requests(to: "/v1/sessions").count
    await settings.loadMoreArchived()
    #expect(server.requests(to: "/v1/sessions").count == reads, "nothing more to ask for")
  }

  @Test("A failed next page keeps the sessions already shown and can be retried")
  func archivedLoadMoreFails() async throws {
    let server = RouteServer()
    server.route("/v1/sessions", archivedPage(["a1", "a2"], hasMore: true))
    let settings = try await settings(server)
    await settings.loadArchived()

    server.fail("/v1/sessions")
    await settings.loadMoreArchived()
    #expect(settings.archived.value?.map(\.id) == ["a1", "a2"])
    #expect(settings.error != nil)
    #expect(settings.hasMoreArchived)

    server.route("/v1/sessions", archivedPage(["a3"], hasMore: false))
    await settings.loadMoreArchived()
    #expect(settings.archived.value?.map(\.id) == ["a1", "a2", "a3"])
    #expect(settings.error == nil)
  }

  @Test("A bulk action drops what worked and names how many didn't")
  func bulkPartial() async throws {
    let server = RouteServer()
    server.route("/v1/sessions", archivedPage(["a1", "a2"], hasMore: false))
    server.route(
      "/v1/sessions/a1",
      .json(
        #"{"id":"a1","title":"a1","status":"idle","created_at":1,"updated_at":2,"archived":true,"permission_level":4,"items":[]}"#
      ))
    let settings = try await settings(server)
    await settings.loadArchived()
    await settings.unarchive(["a1", "a2"])
    #expect(settings.archived.value?.map(\.id) == ["a2"])
    #expect(settings.error?.message.hasPrefix("Could not unarchive 1 of 2 sessions") == true)

    // One session failing shows that session's own error, not a tally.
    await settings.delete(["a2"])
    #expect(settings.archived.value?.map(\.id) == ["a2"])
    #expect(settings.error?.message.hasPrefix("Could not") == false)
    #expect(!settings.isSaving)
  }
}
