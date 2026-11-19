import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

private let address = "http://127.0.0.1:6767"
private let offering =
  #"{"single_user":true,"accounts_enabled":false,"automations_enabled":true,"features":{"usage_page":true}}"#
private let offeringWithoutUsage =
  #"{"single_user":true,"accounts_enabled":false,"automations_enabled":true}"#
private let automationsOff =
  #"{"single_user":true,"accounts_enabled":false,"automations_enabled":false}"#
/// Connects (the sign-in reads only `single_user` and `accounts_enabled`), but no pages decode.
private let undecodablePages =
  #"{"single_user":true,"accounts_enabled":false,"automations_enabled":"soon"}"#

/// A store over `server` whose failed page reads retry after `retryDelay`, connected.
@MainActor
private func connected(
  _ server: RouteServer, retryDelay: Duration = .milliseconds(10)
) async throws -> ConnectionStore {
  let store = try disconnectedStore(server)
  store.offeredPagesRetryDelay = { _ in retryDelay }
  await store.connect(serverURL: address)
  #expect(store.isSignedIn, "phase: \(store.phase)")
  return store
}

/// The pages the server offers follow the connection: read on each connect, wake and renewed
/// credential, retried while a read fails, and kept while a reload runs.
@MainActor
@Suite("Offered pages reload", .timeLimit(.minutes(1)))
struct OfferedPagesReloadTests {
  @Test("A read cut short by a reconnect records nothing, and the reconnect reads them again")
  func reconnectReadsAgain() async throws {
    let server = RouteServer()
    server.route("/v1/info", .json(offering))
    let store = try await connected(server)
    let pages = try #require(store.pages)
    try await eventually("the first read") { pages.offered?.usage == true }
    try await eventually("the session list") { store.sessionList.isLoaded }

    let gate = server.hold("/v1/info")
    store.reloadOfferedPages()
    try await eventually("the held read") { gate.arrivals == 1 }
    let reconnect = Task { await store.connect(serverURL: address) }
    try await eventually("the reconnect to start") { !store.isSignedIn }
    #expect(pages.offered?.automations == true, "the pages stay while the connection is down")
    server.route("/v1/info", .json(offeringWithoutUsage))
    gate.release()
    await reconnect.value

    try await eventually("the reconnect's read") { pages.offered?.usage == false }
    #expect(pages.offered?.automations == true)
    #expect(pages.offeredReadFailure == nil)
    #expect(store.issues.isEmpty, "\(store.issues)")
  }

  @Test("A failed first read is retried until it works, under one issue that then goes")
  func failedFirstReadRetries() async throws {
    let server = RouteServer()
    server.route("/v1/info", .json(undecodablePages))
    let store = try await connected(server)
    let pages = try #require(store.pages)
    try await eventually("the failed read") { pages.offeredReadFailure != nil }
    #expect(pages.offered == nil)
    let reads = server.requests(to: "/v1/info").count
    try await eventually("two retries") { server.requests(to: "/v1/info").count >= reads + 2 }
    #expect(store.issues.count == 1, "one issue for the run of failures: \(store.issues)")
    #expect(store.issues.first?.scope == .connection)

    server.route("/v1/info", .json(offering))
    try await eventually("the retry that works") { pages.offered?.automations == true }
    #expect(pages.offeredReadFailure == nil)
    #expect(pages.offeredError == nil)
    try await eventually("the issue to go") { store.issues.isEmpty }
  }

  @Test("A refresh keeps the pages while it runs and after it fails; a lasting failure is recorded")
  func refreshKeepsThePages() async throws {
    let server = RouteServer()
    server.route("/v1/info", .json(offering))
    let store = try await connected(server, retryDelay: .seconds(30))
    let pages = try #require(store.pages)
    try await eventually("the first read") { pages.offered?.automations == true }

    let gate = server.hold("/v1/info")
    store.foreground()
    try await eventually("the held refresh") { gate.arrivals == 1 }
    #expect(pages.offered?.automations == true, "kept while the refresh runs")
    server.fail("/v1/info")
    gate.release()
    try await eventually("the failed refresh") { pages.offeredError != nil }
    #expect(pages.offered?.automations == true, "kept after it fails")
    #expect(pages.offeredReadFailure == nil, "nothing is missing, so no sign")
    #expect(store.issues.isEmpty, "a refresh is retried quietly first")

    store.offeredPagesRetryDelay = { _ in .milliseconds(10) }
    store.foreground()
    try await eventually("the lasting failure") { store.issues.count == 1 }
    server.route("/v1/info", .json(offering))
    try await eventually("a read that works") { store.issues.isEmpty }
    #expect(pages.offeredError == nil)
  }

  @Test("A renewed credential reads them again, and a page the server turned off goes")
  func serverTurnsAPageOff() async throws {
    let server = RouteServer()
    server.route("/v1/info", .json(offering))
    let store = try await connected(server)
    let pages = try #require(store.pages)
    try await eventually("the first read") { pages.offered?.automations == true }

    server.route("/v1/info", .json(automationsOff))
    store.apply(.credentialRotated(expiresAtMs: nil))
    try await eventually("the read after the renewal") { pages.offered?.automations == false }
    #expect(pages.offeredReadFailure == nil, "off is the server's answer, not a failure")
    #expect(store.issues.isEmpty)
  }

  @Test("Another account starts without the last one's pages, and a read for it lands")
  func anotherAccount() async throws {
    let server = RouteServer()
    server.route("/v1/info", .json(offering))
    let store = try await connected(server)
    let pages = try #require(store.pages)
    try await eventually("the first read") { pages.offered?.automations == true }

    let gate = server.hold("/v1/info")
    var other = try #require(store.connectedServer)
    other.userId = "ada"
    store.apply(.connectionChanged(phase: .connected(server: other)))
    #expect(pages.offered == nil)
    gate.release()
    try await eventually("the other account's read") { pages.offered?.automations == true }
  }

  @Test("Pages the server won't describe stay unoffered; once read, a failed read keeps them")
  func explicitReads() async throws {
    let server = RouteServer()
    server.route("/v1/info", .json(undecodablePages))
    let store = try await connected(server, retryDelay: .seconds(30))
    let pages = try #require(store.pages)
    // The connect's own read, and the retry it waits on, end first: only the reads below count.
    store.offeredPagesReload?.cancel()
    await store.offeredPagesReload?.value
    #expect(await pages.loadOffered() != nil)
    #expect(pages.offered == nil)
    #expect(pages.offeredReadFailure != nil)

    server.route("/v1/info", .json(offering))
    #expect(await pages.loadOffered() == nil)
    server.fail("/v1/info")
    #expect(await pages.loadOffered() != nil)
    #expect(pages.offered?.automations == true)
    #expect(pages.offeredError != nil)
    #expect(pages.offeredReadFailure == nil)
    #expect(store.isSignedIn)
  }

  @Test("Not signed in, nothing is read or recorded")
  func notSignedIn() throws {
    let server = RouteServer()
    let store = try disconnectedStore(server)
    store.reloadOfferedPages()
    store.foreground()
    #expect(store.offeredPagesReload == nil)
    #expect(store.issues.isEmpty)
    #expect(server.requests(to: "/v1/info").isEmpty)
  }

  @Test("Retries wait 1, 2, 4 seconds and so on, at most a minute")
  func backoff() {
    #expect(ConnectionStore.offeredPagesBackoff(1) == .seconds(1))
    #expect(ConnectionStore.offeredPagesBackoff(2) == .seconds(2))
    #expect(ConnectionStore.offeredPagesBackoff(4) == .seconds(8))
    #expect(ConnectionStore.offeredPagesBackoff(7) == .seconds(60))
    #expect(ConnectionStore.offeredPagesBackoff(200) == .seconds(60))
  }
}
