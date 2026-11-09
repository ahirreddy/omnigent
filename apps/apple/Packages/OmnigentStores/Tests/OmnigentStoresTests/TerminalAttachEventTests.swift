import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// The attach events the terminal surfaces depend on arrive in the order the core sent them.
@MainActor
@Suite("Terminal attach events", .timeLimit(.minutes(1)))
struct TerminalAttachEventTests {
  @Test("Callbacks become events in order")
  func relayKeepsOrder() async {
    let relay = TerminalAttachRelay()
    relay.onState(state: .idle)
    relay.onOutput(bytes: Data("hi".utf8))
    relay.onResetScreen()
    relay.onClipboardWrite(text: "copied")
    relay.onInputDropped(byteCount: 3, reason: .notAttached)
    relay.onNotice(message: "odd frame")
    relay.finish()
    var seen: [TerminalAttachEvent] = []
    for await event in relay.events { seen.append(event) }
    #expect(
      seen == [
        .state(.idle), .output(Array("hi".utf8)), .resetScreen, .clipboardWrite("copied"),
        .inputDropped(byteCount: 3, reason: .notAttached), .notice("odd frame"),
      ])
  }

  private func attachSocket(_ sockets: FakeWebSocketTransport) async -> OpenedWebSocket {
    while true {
      let opened = await sockets.waitForOpenedSocket()
      if opened.request.url.contains("/attach") { return opened }
    }
  }

  @Test("Input goes out on the socket, a bad size is refused, and foregrounding reconnects at once")
  func driving() async throws {
    let sockets = FakeWebSocketTransport()
    let store = try await connectedStore(RouteServer(), sockets: sockets)
    let terminals = try #require(store.terminals("conv_a"))
    let attach = terminals.attach(terminalID: "terminal_zsh_u-1", permissionLevel: 4, hostID: nil)
    attach.start()
    let socket = await attachSocket(sockets)
    socket.sink.opened()
    var events = attach.events.makeAsyncIterator()
    while let event = await events.next() {
      if case .state(.attached) = event { break }
    }

    attach.send(Array("hi".utf8))
    try await eventually("the input") { socket.handle.sentBinaries.contains(Data("hi".utf8)) }
    try attach.resize(columns: 80, rows: 24)
    #expect(throws: CoreError.self) { try attach.resize(columns: 0, rows: 0) }

    socket.sink.ended(end: .failed(failure: .offline(message: "connection lost")))
    attach.foreground()
    let next = await attachSocket(sockets)
    next.sink.opened()
    attach.stop()
  }

  @Test("Creating and closing a terminal clears an earlier failure")
  func createAndDelete() async throws {
    let server = RouteServer()
    let path = "/v1/sessions/conv_a/resources/terminals"
    server.fail(path, method: "POST", status: 500)
    server.fail("\(path)/t1", method: "DELETE", status: 500)
    let store = try await connectedStore(server)
    let terminals = try #require(store.terminals("conv_a"))
    #expect(await terminals.create("zsh") == nil)
    #expect(terminals.lastError != nil)

    server.route(
      path, method: "POST",
      .json(
        #"{"id":"terminal_zsh_u-1","name":"zsh:u-1","object":"session.resource","session_id":"conv_a","type":"terminal","metadata":{"running":true,"terminal_name":"zsh","session_key":"u-1"}}"#,
        status: 201))
    #expect(await terminals.create("zsh") != nil)
    #expect(terminals.lastError == nil)

    await terminals.delete("t1")
    #expect(terminals.lastError != nil)
    server.route("\(path)/t1", method: "DELETE", .json(#"{"id":"t1","deleted":true}"#))
    await terminals.delete("t1")
    #expect(terminals.lastError == nil)
  }
}
