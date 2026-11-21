internal import Foundation
internal import Network
internal import Synchronization
internal import os

/// One TCP connection to the DevTools gate: the HTTP upgrade (`GateHandshake`), then RFC 6455
/// frames (`WebSocketFrame`) whose text messages go to the multiplexer.
nonisolated final class GateConnection: Sendable {
  private enum Phase {
    case head, open, closed
  }

  private struct State {
    var phase = Phase.head
    var buffer = Data()
    var message = Data()
    var messageOpen = false
    var clientID: DevToolsMultiplexer.ClientID?
    var onEnd: (@Sendable () -> Void)?
  }

  private let connection: NWConnection
  private let multiplexer: DevToolsMultiplexer
  private let scopeForPath: @Sendable (String) -> String?
  private let state = Mutex(State())

  /// Wraps an accepted connection.
  /// - Parameters:
  ///   - connection: The TCP connection.
  ///   - multiplexer: The pipe's multiplexer.
  ///   - scopeForPath: The scope a request path's secret opens, or `nil`.
  init(
    connection: NWConnection, multiplexer: DevToolsMultiplexer,
    scopeForPath: @escaping @Sendable (String) -> String?
  ) {
    self.connection = connection
    self.multiplexer = multiplexer
    self.scopeForPath = scopeForPath
  }

  /// Starts reading; `onEnd` runs once when the connection ends.
  func start(queue: DispatchQueue, onEnd: @escaping @Sendable () -> Void) {
    state.withLock { $0.onEnd = onEnd }
    connection.stateUpdateHandler = { [weak self] newState in
      switch newState {
      case .failed, .cancelled: self?.finish()
      default: break
      }
    }
    connection.start(queue: queue)
    receive()
  }

  /// Drops the connection.
  func cancel() {
    connection.cancel()
    finish()
  }

  /// Sends one text message.
  func sendText(_ payload: Data) {
    send(WebSocketFrame.encode(opcode: WebSocketFrame.text, payload))
  }

  private static let readSize = 1 << 20

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readSize) { [weak self] in
      self?.received($0, isComplete: $2, error: $3)
    }
  }

  private func received(_ content: Data?, isComplete: Bool, error: NWError?) {
    if let content { consume(content) }
    if error != nil || isComplete {
      cancel()
    } else if state.withLock({ $0.phase != .closed }) {
      receive()
    }
  }

  private func consume(_ bytes: Data) {
    let phase = state.withLock { state in
      state.buffer.append(bytes)
      return state.phase
    }
    switch phase {
    case .head: readHead()
    case .open: readFrames()
    case .closed: break
    }
  }

  private func readHead() {
    let head = state.withLock { state -> Data? in
      guard let end = state.buffer.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
      let head = Data(state.buffer[state.buffer.startIndex..<end.lowerBound])
      state.buffer = Data(state.buffer[end.upperBound...])
      return head
    }
    guard let head else {
      if state.withLock({ $0.buffer.count }) > DevToolsGate.maximumHeadBytes {
        refuse(GateHandshake.Refusal(code: 431, reason: "Request Header Fields Too Large"))
      }
      return
    }
    switch GateHandshake.check(head, scopeForPath: scopeForPath) {
    case .failure(let refusal):
      refuse(refusal)
    case .success(let accepted):
      open(accepted)
    }
  }

  private func open(_ accepted: GateHandshake.Accepted) {
    send(Data(GateHandshake.switchingProtocols(key: accepted.key).utf8))
    let id = multiplexer.addClient(
      scope: accepted.scope,
      send: { [weak self] data in self?.sendText(data) },
      close: { [weak self] in self?.close(code: 1011, reason: "The browser exited.") })
    state.withLock { state in
      state.clientID = id
      state.phase = .open
    }
    readFrames()
  }

  private func refuse(_ refusal: GateHandshake.Refusal) {
    DevToolsGate.log.info("The DevTools gate refused a connection: \(refusal.code)")
    state.withLock { $0.phase = .closed }
    connection.send(
      content: Data(GateHandshake.refusal(refusal).utf8),
      completion: .contentProcessed { [weak self] _ in self?.cancel() })
  }

  private func readFrames() {
    while true {
      let next = state.withLock { state in WebSocketFrame.take(from: &state.buffer) }
      switch next {
      case nil:
        return
      case .failure(let problem):
        close(code: problem.code, reason: problem.reason)
        return
      case .success(let frame):
        guard handle(frame) else { return }
      }
    }
  }

  /// Handles one frame; returns false once the connection is closing.
  private func handle(_ frame: WebSocketFrame) -> Bool {
    switch frame.opcode {
    case WebSocketFrame.continuation, WebSocketFrame.text, WebSocketFrame.binary:
      return collect(frame)
    case WebSocketFrame.close:
      close(code: 1000, reason: "")
      return false
    case WebSocketFrame.ping:
      send(WebSocketFrame.encode(opcode: WebSocketFrame.pong, frame.payload))
      return true
    case WebSocketFrame.pong:
      return true
    default:
      close(code: 1002, reason: "Unknown opcode")
      return false
    }
  }

  /// Adds a data frame to the message it belongs to and passes on a finished message.
  private func collect(_ frame: WebSocketFrame) -> Bool {
    let finished = state.withLock { state -> Data? in
      if frame.opcode != WebSocketFrame.continuation {
        state.message = Data()
        state.messageOpen = true
      }
      guard state.messageOpen else { return nil }
      state.message.append(frame.payload)
      guard frame.final else { return nil }
      state.messageOpen = false
      defer { state.message = Data() }
      return state.message
    }
    guard let finished else { return true }
    guard finished.count <= DevToolsGate.maximumMessageBytes else {
      close(code: 1009, reason: "Message too big")
      return false
    }
    if let id = state.withLock({ $0.clientID }) { multiplexer.clientMessage(id, finished) }
    return true
  }

  private func send(_ data: Data) {
    connection.send(
      content: data,
      completion: .contentProcessed { [weak self] error in
        if error != nil { self?.cancel() }
      })
  }

  private func close(code: UInt16, reason: String) {
    let wasOpen = state.withLock { state in
      defer { state.phase = .closed }
      return state.phase == .open
    }
    guard wasOpen else { return }
    var payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
    payload.append(Data(reason.utf8))
    send(WebSocketFrame.encode(opcode: WebSocketFrame.close, payload))
    connection.send(
      content: nil, isComplete: true,
      completion: .contentProcessed { [weak self] _ in self?.cancel() })
  }

  private func finish() {
    let ended = state.withLock { state in
      defer {
        state.phase = .closed
        state.clientID = nil
        state.onEnd = nil
      }
      return (state.clientID, state.onEnd)
    }
    if let id = ended.0 { multiplexer.removeClient(id) }
    ended.1?()
  }
}
