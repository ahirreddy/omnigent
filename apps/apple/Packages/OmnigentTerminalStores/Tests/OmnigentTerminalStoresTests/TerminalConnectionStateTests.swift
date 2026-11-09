import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTerminalUI
import OmnigentTestSupport
import OmnigentViewTesting
import Testing

@testable import OmnigentStores
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

/// The next socket opened for a terminal attach, past the session-updates socket.
private func attachSocket(_ sockets: FakeWebSocketTransport) async -> OpenedWebSocket {
  while true {
    let opened = await sockets.waitForOpenedSocket()
    if opened.request.url.contains("/attach") { return opened }
  }
}

/// A started connection whose socket has opened.
@MainActor
private struct AttachedTerminal {
  let store: ConnectionStore
  let connection: CoreTerminalConnection
  let socket: OpenedWebSocket
  let sockets: FakeWebSocketTransport

  init(permissionLevel: Int64 = 4) async throws {
    sockets = FakeWebSocketTransport()
    store = try await connectedStore(sockets: sockets)
    let terminals = try #require(store.terminals("conv_a"))
    let connection = CoreTerminalConnection(
      attach: terminals.attach(
        terminalID: "terminal_zsh_u-1", permissionLevel: permissionLevel, hostID: nil))
    self.connection = connection
    #expect(connection.state == .idle)
    connection.start()
    socket = await attachSocket(sockets)
    socket.sink.opened()
    let readOnly = permissionLevel < 4
    try await eventuallyTrue { connection.state == .attached(readOnly: readOnly) }
  }

  /// Output until `bytes` arrives, so anything sent before it is skipped.
  func read(_ bytes: [UInt8]) async -> Bool {
    for await output in connection.output where output == .bytes(bytes) { return true }
    return false
  }
}

private func eventuallyTrue(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(10)
  while !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("timed out")
      return
    }
    try await Task.sleep(for: .milliseconds(5))
  }
}

@MainActor
@Suite("Terminal connection state", .timeLimit(.minutes(1)))
struct TerminalConnectionStateTests {
  private let reason = CoreError.InvalidState(message: "dropped")

  @Test("Every attach state maps to what the terminal view shows")
  func stateTable() {
    let map = CoreTerminalConnection.state
    #expect(map(.idle) == .idle)
    #expect(map(.connecting) == .connecting)
    #expect(map(.attached(readOnly: true)) == .attached(readOnly: true))
    #expect(map(.stopped) == .closed(.stopped))
    #expect(
      map(.closed(reason: .terminalEnded(reason: "exit")))
        == .closed(.terminalEnded(reason: "exit")))
    #expect(map(.closed(reason: .detached(reason: "d"))) == .closed(.detached(reason: "d")))
    #expect(
      map(.closed(reason: .serverClosed(code: 4500, reason: "s")))
        == .closed(.serverClosed(code: 4500, reason: "s")))
    #expect(
      map(.reconnecting(reason: reason, failures: 3, delayMs: 250))
        == .reconnecting(failures: 3, retryInMilliseconds: 250, reason: "dropped"))
  }

  @Test("A huge retry delay can't trap the conversion")
  func hugeDelay() {
    let state = CoreTerminalConnection.state(
      .reconnecting(reason: reason, failures: .max, delayMs: .max))
    guard case .reconnecting(let failures, let delay, _) = state else {
      Issue.record("state: \(state)")
      return
    }
    #expect(failures == Int(UInt32.max))
    #expect(delay == Int.max)
  }

  @Test(
    "Only a refused read-write attach offers read-only",
    arguments: [
      (TerminalAttachFailure.accessDenied(detail: "x", readOnly: false), true),
      (.accessDenied(detail: "x", readOnly: true), false),
      (.authenticationRequired(detail: "x"), false),
      (.serverError(reason: "x"), false),
      (.wrongReplica, false),
    ])
  func readOnlyOffer(failure: TerminalAttachFailure, offersReadOnly: Bool) {
    let state = CoreTerminalConnection.state(
      .failed(failure: failure, message: "m", requiresSignIn: true))
    guard case .failed(let mapped) = state else {
      Issue.record("state: \(state)")
      return
    }
    #expect(mapped.readOnlyMayWork == offersReadOnly)
    #expect(mapped.requiresSignIn)
    #expect(mapped.message == "m")
  }

  @Test("Input on a read-only attach is counted, never buffered for later")
  func readOnlyInput() async throws {
    let terminal = try await AttachedTerminal(permissionLevel: 2)
    #expect(!terminal.connection.state.acceptsInput)
    terminal.connection.send([1, 2, 3])
    try await eventuallyTrue { terminal.connection.droppedInputBytes == 3 }
    #expect(terminal.socket.handle.sentBinaries.isEmpty)
    terminal.socket.sink.message(message: .binary(bytes: Data("seed".utf8)))
    #expect(await terminal.read(Array("seed".utf8)))
  }

  @Test("Input reaches the socket once attached read-write")
  func writableInput() async throws {
    let terminal = try await AttachedTerminal()
    #expect(terminal.connection.state.acceptsInput)
    terminal.connection.send([104, 105])
    try await eventuallyTrue { terminal.socket.handle.sentBinaries.contains(Data([104, 105])) }
    #expect(terminal.connection.droppedInputBytes == 0)
  }

  @Test("A dropped socket reconnects and attaches again; frames resume on the new socket")
  func reconnects() async throws {
    let terminal = try await AttachedTerminal()
    let connection = terminal.connection
    terminal.socket.sink.ended(end: .failed(failure: .offline(message: "connection lost")))
    try await eventuallyTrue {
      if case .reconnecting = connection.state { return true }
      return false
    }
    // Coming to the foreground runs the pending reconnect now, not after the backoff.
    connection.foreground()
    let next = await attachSocket(terminal.sockets)
    next.sink.opened()
    try await eventuallyTrue { connection.state == .attached(readOnly: false) }
    next.sink.message(message: .binary(bytes: Data("back".utf8)))
    #expect(await terminal.read(Array("back".utf8)))
  }

  @Test("Close codes name why the terminal ended, and stopping is a stop")
  func closes() async throws {
    let ended = try await AttachedTerminal()
    ended.socket.sink.ended(end: .closed(code: 4404, reason: "gone"))
    try await eventuallyTrue {
      if case .closed(.terminalEnded) = ended.connection.state { return true }
      return false
    }

    let detached = try await AttachedTerminal()
    detached.socket.sink.ended(end: .closed(code: 4405, reason: "moved"))
    try await eventuallyTrue {
      if case .closed(.detached) = detached.connection.state { return true }
      return false
    }

    let stopped = try await AttachedTerminal()
    stopped.connection.stop()
    try await eventuallyTrue { stopped.connection.state == .closed(.stopped) }
  }

  @Test("A size the core refuses becomes a notice, capped at the newest fifty")
  func resizeNotices() async throws {
    let terminal = try await AttachedTerminal()
    terminal.connection.resize(try #require(TerminalGridSize(columns: 80, rows: 24)))
    #expect(terminal.connection.notices.isEmpty)

    let huge = try #require(TerminalGridSize(columns: 1_000_000, rows: 1_000_000))
    for _ in 0..<60 { terminal.connection.resize(huge) }
    #expect(terminal.connection.notices.count == 50)
    #expect(terminal.connection.notices.last?.contains("Could not resize") == true)
    terminal.connection.dismissNotices()
    #expect(terminal.connection.notices.isEmpty)
    #expect(terminal.connection.sessionID == "conv_a")
    #expect(terminal.connection.terminalID == "terminal_zsh_u-1")
  }
}

/// One session's surfaces, with no window and no real clipboard.
@MainActor
@Suite("Terminal surfaces per session", .serialized, .timeLimit(.minutes(1)))
struct TerminalStoreTests {
  init() {
    SystemSideEffects.install()
    SystemSideEffects.reset()
  }

  private func terminalStore() async throws -> (ConnectionStore, TerminalStore) {
    let store = try await connectedStore(sockets: FakeWebSocketTransport())
    return (store, TerminalStore(terminals: try #require(store.terminals("conv_a"))))
  }

  @Test("A terminal keeps one surface across view changes until it is closed")
  func surfaceLifetime() async throws {
    let (_, store) = try await terminalStore()
    #expect(store.sessionID == "conv_a")
    let first = try #require(store.controller(for: "t1", permissionLevel: 4, hostID: nil))
    #expect(store.lastError == nil)
    #expect(store.controller(for: "t1", permissionLevel: 4, hostID: nil) === first)
    let second = try #require(store.controller(for: "t2", permissionLevel: 4, hostID: nil))
    #expect(second !== first)
    #expect(store.controllers.count == 2)
    store.foreground()

    store.close("t1")
    #expect(store.controllers["t1"] == nil)
    #expect(store.controllers.count == 1)
    store.close("never opened")
    #expect(store.controller(for: "t1", permissionLevel: 4, hostID: nil) !== first)
  }

  @Test("A renderer that can't start says so and makes no surface, and a later try can succeed")
  func rendererFails() async throws {
    let connection = try await connectedStore(sockets: FakeWebSocketTransport())
    var failure: GhosttyError? = .appCreationFailed
    let store = TerminalStore(
      terminals: try #require(connection.terminals("conv_a"))
    ) { terminal throws(GhosttyError) in
      if let failure { throw failure }
      return try TerminalSurfaceController(connection: terminal)
    }

    #expect(store.controller(for: "t1", permissionLevel: 4, hostID: nil) == nil)
    #expect(store.lastError == .appCreationFailed)
    #expect(store.controllers.isEmpty)

    failure = nil
    #expect(store.controller(for: "t1", permissionLevel: 4, hostID: nil) != nil)
    #expect(store.lastError == nil)
    #expect(store.controllers.count == 1)
  }

  @Test("The harness surface exists only once the core says it is ready")
  func harnessSurface() async throws {
    let (_, store) = try await terminalStore()
    #expect(store.harnessController(permissionLevel: 4, hostID: nil) == nil)
    #expect(store.controllers.isEmpty)

    store.terminals.apply(terminals: [], harness: .startingUp)
    #expect(store.harnessController(permissionLevel: 4, hostID: nil) == nil)

    let harness = TerminalResource(
      id: "terminal_agent", sessionId: "conv_a", terminalName: "agent", sessionKey: "key",
      running: true, environment: nil, directAttachUrl: nil, isAgentTerminal: true,
      displayLabel: "Agent")
    store.terminals.apply(terminals: [], harness: .ready(terminal: harness))
    let surface = try #require(store.harnessController(permissionLevel: 4, hostID: nil))
    #expect(store.controllers["terminal_agent"] === surface)
    #expect(store.harnessController(permissionLevel: 4, hostID: nil) === surface)
  }
}
