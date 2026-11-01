import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import Testing

@MainActor
struct AppConnectionTests {
  @Test func coreReportsVersion() {
    #expect(!coreVersion().isEmpty)
  }

  @Test func storeDiscoversThroughRustCore() async throws {
    let store = ConnectionStore(
      transport: FakeHttpTransport(routes: [
        "/.well-known/omnigent.json": .json(ManifestFixtures.localNoAuth)
      ])
    )

    await store.discover(serverURL: "http://127.0.0.1:6767")

    let discovery = try #require(store.discovery, "state: \(store.state)")
    #expect(discovery.serverName == "Local Omnigent")
    #expect(discovery.authMode == AuthMode.none)
  }
}
