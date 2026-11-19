import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// When the connection's warnings show and clear, and when "Reconnected" says it is back: only
/// after a disruption the user could see, never at launch, after a healthy socket recycle or
/// after a switch to another server.
@MainActor
@Suite("Connection recovery", .timeLimit(.minutes(1)))
struct ConnectionRecoveryTests {
  private let server = "http://127.0.0.1:6767"
  private let lost = CoreError.Link(
    kind: .connection, message: "connection lost", requiresSignIn: false)
  private let unreachable = CoreError.Transport(kind: .offline, message: "refused")
  private let expired = CoreError.Auth(
    kind: .credentialExpired, failure: .expired, message: "Sign in again", detail: nil)

  private var outage: ReachabilitySignal {
    .disrupted(.reconnecting(reason: lost, failures: 2))
  }

  /// Applies each step in order: which ended a disruption, and the warning left.
  private func observe(_ steps: [(server: String?, signal: ReachabilitySignal)]) -> (
    returns: [Bool], left: ConnectionReachability
  ) {
    var recovery = ConnectionRecovery()
    let returns = steps.map { recovery.observe(server: $0.server, signal: $0.signal) }
    return (returns, recovery.reachability)
  }

  @Test("The first connect and a healthy socket recycle are not returns")
  func noFalseReturn() {
    let seen = observe([
      (server, .unsettled), (server, .reachable), (server, .unsettled), (server, .reachable),
    ])
    #expect(seen.returns == [false, false, false, false])
    #expect(seen.left == .online)
  }

  @Test("An outage shows until the link is live again, and its end is a return once")
  func outageReturnsOnce() {
    let shown = observe([(server, .reachable), (server, outage), (server, .unsettled)])
    #expect(shown.left == .reconnecting(reason: lost, failures: 2), "a new attempt is no return")
    let seen = observe([
      (server, .reachable), (server, outage), (server, .unsettled), (server, .reachable),
      (server, .reachable),
    ])
    #expect(seen.returns == [false, false, false, true, false], "said once")
    #expect(seen.left == .online)
  }

  @Test("A switch to another server, or a sign-out, drops the disruption with no return")
  func switchIsNoReturn() {
    let switched = observe([(server, outage), ("https://other.example.com", .reachable)])
    #expect(switched.returns == [false, false])
    #expect(switched.left == .online)
    let signedOut = observe([(server, outage), (nil, .unsettled), (server, .reachable)])
    #expect(signedOut.returns == [false, false, false])
    #expect(signedOut.left == .online)
  }

  @Test("Offline at launch, then connected to the same server as typed, is a return")
  func offlineLaunchReturns() {
    let connecting = observe([
      ("HTTP://127.0.0.1:6767/", .disrupted(.offline)), (server, .unsettled),
    ])
    #expect(connecting.left == .offline, "connecting again")
    let seen = observe([
      ("HTTP://127.0.0.1:6767/", .disrupted(.offline)), (server, .unsettled), (server, .reachable),
    ])
    #expect(seen.returns == [false, false, true])
  }

  @Test("Reconnected shows for its moment, and a new disruption takes it down at once")
  func noticeLifetime() async throws {
    let health = ConnectionHealth()
    health.noticeDuration = .milliseconds(50)
    _ = health.observe(server: server, signal: outage)
    #expect(health.observe(server: server, signal: .reachable))
    #expect(health.showsReconnected)
    #expect(health.reconnections == 1)
    try await eventually("the notice to go") { !health.showsReconnected }

    health.noticeDuration = .seconds(30)
    _ = health.observe(server: server, signal: outage)
    _ = health.observe(server: server, signal: .reachable)
    #expect(health.showsReconnected)
    _ = health.observe(server: server, signal: outage)
    #expect(!health.showsReconnected, "down again: the warning, not the notice")
    #expect(health.reconnections == 2)
  }

  @Test("A healthy socket recycle and a sign-out shows no notice on the store")
  func storeNoFalseReturn() async throws {
    let store = try await connectedStore(RouteServer())
    store.apply(.updatesLinkChanged(state: .live))
    store.apply(.updatesLinkChanged(state: .reconnecting(reason: lost, failures: 0, delayMs: 0)))
    #expect(store.health.reachability == .online, "a recycle shows nothing")
    store.apply(.updatesLinkChanged(state: .live))
    #expect(!store.health.showsReconnected)

    store.apply(.updatesLinkChanged(state: .reconnecting(reason: lost, failures: 1, delayMs: 250)))
    #expect(store.health.reachability.isDisrupted)
    store.apply(.connectionChanged(phase: .disconnected))
    store.apply(.updatesLinkChanged(state: .live))
    #expect(store.health.reachability == .online)
    #expect(!store.health.showsReconnected, "an ended connection is no return")
    #expect(store.health.reconnections == 0)
  }

  @Test("A link that gave up for sign-in is the sign-in screen's to show, not a disruption")
  func signInFailureIsNotUnreachable() async throws {
    let store = try await connectedStore(RouteServer())
    let refused = CoreError.Link(kind: .httpStatus, message: "401", requiresSignIn: true)
    store.apply(.updatesLinkChanged(state: .failed(error: refused)))
    #expect(store.health.reachability == .online)
    store.apply(.updatesLinkChanged(state: .failed(error: lost)))
    #expect(store.health.reachability == .unreachable(lost))
  }

  @Test("The server going away and coming back clears connection failures and keeps the rest")
  func outageAndReturn() async throws {
    let sockets = FakeWebSocketTransport()
    let store = try await connectedStore(RouteServer(), sockets: sockets)
    store.health.noticeDuration = .seconds(30)
    let conversation = try #require(store.conversation("conv_a"))
    #expect(store.workspace("conv_a") != nil)
    let first = await sockets.waitForOpenedSocket()
    first.sink.opened()
    first.sink.message(message: .text(text: #"{"type":"snapshot","items":[]}"#))
    try await eventually("the socket to go live") { store.updatesLink == .live }
    #expect(!store.health.showsReconnected, "the first connect is no return")

    store.apply(.error(scope: .sessionList, error: unreachable))
    store.apply(.error(scope: .connection, error: expired))
    store.apply(.error(scope: .session(sessionId: "conv_a"), error: unreachable))
    sockets.failConnects(with: .Offline(message: "refused"))
    first.sink.ended(end: .failed(failure: .offline(message: "connection lost")))
    try await eventually("the warning") { store.health.reachability.isDisrupted }
    #expect(!store.health.showsReconnected)

    sockets.failConnects(with: nil)
    let next = await sockets.waitForOpenedSocket()
    next.sink.opened()
    next.sink.message(message: .text(text: #"{"type":"snapshot","items":[]}"#))
    try await eventually("the return") { store.health.showsReconnected }
    #expect(store.health.reachability == .online)
    #expect(store.health.reconnections == 1)
    #expect(
      store.issues.contains { $0.error == expired }, "a failure that is not the network stays")
    #expect(!store.issues.contains { $0.error.isConnectivityProblem })
    #expect(store.sessionList.lastError == nil)
    #expect(!conversation.errors.contains(unreachable))
    #expect(store.fileChanges(in: "conv_a") == 1, "changes pushed while away are read again")
  }

  @Test("Connection failures are the network's; sign-in, refusals and doubtful sends are not")
  func connectivityClassification() {
    #expect(unreachable.isConnectivityProblem)
    #expect(lost.isConnectivityProblem)
    #expect(CoreError.HttpStatus(status: 503, body: "").isConnectivityProblem)
    #expect(!CoreError.HttpStatus(status: 409, body: "").isConnectivityProblem)
    #expect(!CoreError.Transport(kind: .cancelled, message: "").isConnectivityProblem)
    #expect(!expired.isConnectivityProblem)
    #expect(
      !CoreError.Link(kind: .notFound, message: "gone", requiresSignIn: false)
        .isConnectivityProblem)
    let doubtful = CoreError.Session(
      kind: .transport, message: "lost", detail: nil, requiresSignIn: false,
      deliveryUncertain: true)
    #expect(!doubtful.isConnectivityProblem)
    let offline = CoreError.Session(
      kind: .transport, message: "lost", detail: nil, requiresSignIn: false,
      deliveryUncertain: false)
    #expect(offline.isConnectivityProblem)
  }
}
