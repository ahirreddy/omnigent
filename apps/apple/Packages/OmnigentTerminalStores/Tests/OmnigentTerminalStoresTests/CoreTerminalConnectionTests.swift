import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentStores
import OmnigentTerminalUI
import OmnigentTestSupport
import Testing

@testable import OmnigentTerminalStores

@MainActor
private func connectedStore(sockets: FakeWebSocketTransport) async throws -> ConnectionStore {
  let routes: [String: HttpResponse] = [
    "/.well-known/omnigent.json": .json(ManifestFixtures.localNoAuth),
    "/v1/info": .json(#"{"single_user":true,"accounts_enabled":false}"#),
    "/v1/me": .json(#"{"user_id":"local"}"#),
    "/v1/sessions": .json(#"{"object":"list","data":[],"has_more":false}"#),
  ]
  let core = try ClientCore(
    http: FakeHttpTransport(routes: routes), streams: FakeEventStreamTransport(),
    sockets: sockets, clock: SystemClock(), scheduler: TaskScheduler(),
    secureStore: InMemorySecureStore(), entropy: FixedEntropySource(),
    config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
  let store = ConnectionStore(core: core)
  await store.connect(serverURL: "http://127.0.0.1:6767")
  #expect(store.isSignedIn, "phase: \(store.phase)")
  return store
}

/// The next socket the core opens whose URL contains `fragment` (the session-updates socket
/// opens first on every connect).
private func socket(_ sockets: FakeWebSocketTransport, containing fragment: String) async
  -> OpenedWebSocket
{
  while true {
    let opened = await sockets.waitForOpenedSocket()
    if opened.request.url.contains(fragment) { return opened }
  }
}

@MainActor
struct CoreTerminalConnectionTests {
  @Test(.timeLimit(.minutes(1)))
  func mapsTheCoreAttachOntoTheTerminalConnectionContract() async throws {
    let sockets = FakeWebSocketTransport()
    let store = try await connectedStore(sockets: sockets)
    let terminals = try #require(store.terminals("conv_a"))
    let connection = CoreTerminalConnection(
      attach: terminals.attach(terminalID: "terminal_zsh_u-1", permissionLevel: 2, hostID: nil))
    var states = connection.states.makeAsyncIterator()
    var output = connection.output.makeAsyncIterator()
    #expect(await states.next() == .idle)

    connection.start()
    #expect(await states.next() == .connecting)
    let opened = await socket(sockets, containing: "/attach")
    #expect(opened.request.url.contains("read_only=true"), "below owner attaches read-only")
    opened.sink.opened()
    #expect(await states.next() == .attached(readOnly: true))
    #expect(!connection.state.acceptsInput)

    opened.sink.message(message: .binary(bytes: Data("seed".utf8)))
    #expect(await output.next() == .bytes(Array("seed".utf8)))

    opened.sink.ended(end: .closed(code: 4405, reason: "detached"))
    #expect(await states.next() == .closed(.detached(reason: "detached")))
  }

  @Test(.timeLimit(.minutes(1))) func failuresKeepTheirMessageAndSignInFlag() {
    let state = CoreTerminalConnection.state(
      .failed(
        failure: .accessDenied(detail: "owner only", readOnly: false),
        message: "not allowed to attach to this terminal: owner only", requiresSignIn: false))
    guard case .failed(let failure) = state else {
      Issue.record("state: \(state)")
      return
    }
    #expect(failure.readOnlyMayWork)
    #expect(!failure.requiresSignIn)
    #expect(failure.message.contains("owner only"))
    #expect(CoreTerminalConnection.state(.stopped) == .closed(.stopped))
  }
}
