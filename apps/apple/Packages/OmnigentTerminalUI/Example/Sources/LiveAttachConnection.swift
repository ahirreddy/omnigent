import Foundation
import OmnigentTerminalUI

/// A deliberately minimal attach client for the gallery's `-attach` mode: one WebSocket, no
/// reconnect, no auth. The app's real connection is the core's `TerminalAttach` state machine
/// over the shared URLSession transport; this exists only to show a live local-server terminal.
final class LiveAttachConnection: TerminalConnection {
  let output: AsyncStream<TerminalOutput>
  let states: AsyncStream<TerminalConnectionState>
  private(set) var state: TerminalConnectionState = .idle
  private let url: URL
  private let outputContinuation: AsyncStream<TerminalOutput>.Continuation
  private let stateContinuation: AsyncStream<TerminalConnectionState>.Continuation
  private var socket: URLSessionWebSocketTask?
  private var size: TerminalGridSize?

  init(url: URL) {
    self.url = url
    (output, outputContinuation) = AsyncStream.makeStream()
    (states, stateContinuation) = AsyncStream.makeStream()
    stateContinuation.yield(.idle)
  }

  func start() {
    guard socket == nil else { return }
    set(.connecting)
    let socket = URLSession.shared.webSocketTask(with: url)
    self.socket = socket
    socket.resume()
    Task { await receive(socket) }
  }

  func stop() {
    socket?.cancel(with: .normalClosure, reason: nil)
    socket = nil
    set(.closed(.stopped))
  }

  func foreground() {}

  func send(_ bytes: [UInt8]) {
    guard let socket, state.acceptsInput else { return }
    Task { await deliver(.data(Data(bytes)), on: socket) }
  }

  func resize(_ size: TerminalGridSize) {
    self.size = size
    guard let socket, case .attached = state else { return }
    sendSize(on: socket)
  }

  private func sendSize(on socket: URLSessionWebSocketTask) {
    guard let size else { return }
    let text = "{\"type\":\"resize\",\"cols\":\(size.columns),\"rows\":\(size.rows)}"
    Task { await deliver(.string(text), on: socket) }
  }

  private func deliver(
    _ message: URLSessionWebSocketTask.Message, on socket: URLSessionWebSocketTask
  )
    async
  {
    do {
      try await socket.send(message)
    } catch {
      set(.failed(TerminalFailure(message: "Sending failed: \(error.localizedDescription)")))
    }
  }

  private func receive(_ socket: URLSessionWebSocketTask) async {
    while true {
      let message: URLSessionWebSocketTask.Message
      do {
        message = try await socket.receive()
      } catch {
        finish(socket, error: error)
        return
      }
      if case .connecting = state {
        set(.attached(readOnly: false))
        sendSize(on: socket)
      }
      switch message {
      case .data(let data): outputContinuation.yield(.bytes(Array(data)))
      case .string: continue
      @unknown default: continue
      }
    }
  }

  private func finish(_ socket: URLSessionWebSocketTask, error: any Error) {
    let code = socket.closeCode.rawValue
    let reason = socket.closeReason.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    switch code {
    case 4404: set(.closed(.terminalEnded(reason: reason)))
    case 4405: set(.closed(.detached(reason: reason)))
    case 0: set(.failed(TerminalFailure(message: error.localizedDescription)))
    default: set(.closed(.serverClosed(code: code, reason: reason)))
    }
  }

  private func set(_ state: TerminalConnectionState) {
    guard self.state != state else { return }
    self.state = state
    stateContinuation.yield(state)
  }
}
