import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

@MainActor
struct ServerSettingsStoreTests {
  @Test(.timeLimit(.minutes(1))) func loadsArchivedPagesAndKeepsBulkFailuresVisible() async throws {
    let server = RouteServer()
    server.route(
      "/v1/sessions",
      .json(
        #"""
        {"object":"list","has_more":false,"data":[
          {"id":"a1","title":"Old","status":"idle","created_at":1,"updated_at":2,"archived":true},
          {"id":"a2","title":"Older","status":"idle","created_at":1,"updated_at":1,"archived":true},
          {"id":"b1","title":"Live","status":"idle","created_at":1,"updated_at":3,"archived":false}]}
        """#))
    let settings = try #require(try await connectedStore(server).serverSettings())
    await settings.loadArchived()
    #expect(settings.archived.value?.map(\.id) == ["a1", "a2"])
    #expect(!settings.hasMoreArchived)

    // The sessions are gone from the server: both deletes fail and both rows stay.
    await settings.delete(["a1", "a2"])
    #expect(settings.archived.value?.count == 2)
    #expect(settings.error?.message.hasPrefix("Could not delete 2 of 2 sessions") == true)
    #expect(!settings.isSaving)
  }

  @Test(.timeLimit(.minutes(1))) func togglesAPolicyInPlaceAndReportsRejectedWrites() async throws {
    let server = RouteServer()
    server.route(
      "/v1/policies", method: "GET",
      .json(#"{"object":"list","data":[{"id":"p1","name":"Ask","handler":"a.b","enabled":true}]}"#))
    server.route(
      "/v1/policies/p1", method: "PATCH",
      .json(#"{"id":"p1","name":"Ask","handler":"a.b","enabled":false}"#))
    server.route(
      "/auth/users/me/password", method: "POST",
      .json(#"{"error":"old password incorrect"}"#, status: 401))
    let settings = try #require(try await connectedStore(server).serverSettings())
    await settings.loadPolicies()
    await settings.setPolicyEnabled("p1", false)
    #expect(settings.policies.value?.first?.enabled == false)
    #expect(settings.error == nil)

    let changed = await settings.changePassword(current: "old", new: "short")
    #expect(!changed)
    #expect(settings.error != nil)
  }

  @Test(.timeLimit(.minutes(1))) func readsCapabilitiesForTheSettingsPanes() async throws {
    let server = RouteServer()
    let settings = try #require(try await connectedStore(server).serverSettings())
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":false,"accounts_enabled":true,"enabled_connections":["mcp","github"]}"#))
    server.route("/v1/me", .json(#"{"user_id":"ada","is_admin":true}"#))
    await settings.loadInfo()
    let info = try #require(settings.info.value)
    #expect(info.isAdmin && info.accountsEnabled && info.mcpRegistry)
    #expect(info.connections == ["github"])
  }
}
