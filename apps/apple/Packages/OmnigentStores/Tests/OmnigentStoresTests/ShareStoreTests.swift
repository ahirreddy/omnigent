import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

@MainActor
struct ShareStoreTests {
  @Test(.timeLimit(.minutes(1))) func readsGrantsAndKeepsAFailedWriteForTheSheet() async throws {
    let server = RouteServer()
    server.route(
      "/v1/sessions/conv_a/permissions",
      .json(
        #"{"permissions":[{"user_id":"local","level":4},{"user_id":"__public__","level":1}],"next_cursor":null}"#
      ))
    server.route(
      "/v1/sessions/conv_a/permissions", method: "PUT",
      .json(#"{"detail":"Sharing has been disabled for this Omnigent server."}"#, status: 403))
    let store = try await connectedStore(server)
    let share = try #require(store.share(sessionID: "conv_a"))
    await share.load()
    #expect(share.grants.value?.count == 2)
    #expect(share.isPublic)
    await share.grant("bob@example.com", level: 2)
    #expect(share.error != nil)
    #expect(!share.isSaving)
  }
}
