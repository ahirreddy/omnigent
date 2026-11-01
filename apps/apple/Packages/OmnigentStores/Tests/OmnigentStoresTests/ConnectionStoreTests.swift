import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

@MainActor
struct ConnectionStoreTests {
  @Test func startsIdle() {
    let store = ConnectionStore(
      transport: FakeHttpTransport(failingWith: .Other(message: "unused")))
    #expect(store.state == .idle)
  }

  @Test func discoverConnectsWithParsedManifest() async throws {
    let transport = FakeHttpTransport(routes: [
      "/.well-known/omnigent.json": .json(ManifestFixtures.localNoAuth)
    ])
    let store = ConnectionStore(transport: transport)

    await store.discover(serverURL: "http://127.0.0.1:6767")

    let discovery = try #require(store.discovery, "state: \(store.state)")
    #expect(discovery.serverName == "Local Omnigent")
    #expect(discovery.serverVersion == "0.42.0")
    #expect(discovery.authMode == AuthMode.none)
    #expect(transport.requests.map(\.url) == ["http://127.0.0.1:6767/.well-known/omnigent.json"])
    #expect(transport.requests.first?.method == "GET")
  }

  @Test func discoverParsesOidcRedirects() async throws {
    let transport = FakeHttpTransport(routes: [
      "/.well-known/omnigent.json": .json(ManifestFixtures.oidc)
    ])
    let store = ConnectionStore(transport: transport)

    await store.discover(serverURL: "https://omnigent.example.com/")

    let discovery = try #require(store.discovery, "state: \(store.state)")
    #expect(discovery.serverName == nil)
    #expect(discovery.authMode == .oidc)
    #expect(discovery.nativeRedirectUris.contains("ai.omnigent.ios:/oauth/callback"))
  }

  @Test func transportFailureIsSurfaced() async throws {
    let store = ConnectionStore(
      transport: FakeHttpTransport(failingWith: .Offline(message: "no route to host")))

    await store.discover(serverURL: "http://127.0.0.1:6767")

    let message = try #require(store.errorMessage, "state: \(store.state)")
    #expect(message.contains("no route to host"))
  }

  @Test func serverErrorIsSurfaced() async throws {
    let transport = FakeHttpTransport { _ in .json(#"{"detail":"boom"}"#, status: 500) }
    let store = ConnectionStore(transport: transport)

    await store.discover(serverURL: "http://127.0.0.1:6767")

    let message = try #require(store.errorMessage, "state: \(store.state)")
    #expect(message.contains("500"))
  }

  @Test func invalidURLIsSurfaced() async throws {
    let transport = FakeHttpTransport(failingWith: .Other(message: "should not be called"))
    let store = ConnectionStore(transport: transport)

    await store.discover(serverURL: "not a url")

    #expect(store.errorMessage != nil, "state: \(store.state)")
    #expect(transport.requests.isEmpty)
  }

  @Test func resetReturnsToIdle() async {
    let store = ConnectionStore(
      transport: FakeHttpTransport(failingWith: .Timeout(message: "slow")))
    await store.discover(serverURL: "http://127.0.0.1:6767")
    store.reset()
    #expect(store.state == .idle)
  }
}
