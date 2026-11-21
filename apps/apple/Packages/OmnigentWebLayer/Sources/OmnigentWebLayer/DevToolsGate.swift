internal import Foundation
internal import Network
internal import Synchronization
internal import os

/// Where an agent's DevTools proxy reaches this Mac's browser: `ws://127.0.0.1:<port><path>`.
/// The path carries a secret for one scope, so treat it like a password: never log it.
nonisolated public struct AgentDevToolsEndpoint: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  /// The loopback TCP port.
  public let port: Int
  /// `/devtools/browser/<secret>`.
  public let path: String

  /// The port only: interpolating an endpoint into a log line must not leak its secret.
  public var description: String { "127.0.0.1:\(port) (secret path withheld)" }
  /// Same as `description`.
  public var debugDescription: String { description }
}

/// The loopback WebSocket front of Chromium's DevTools pipe.
///
/// It listens only while an agent needs it: the first `endpoint(scope:)` opens it, and it closes
/// once no connection has been open for `idleTimeout`. Each scope (an Omnigent session) gets its
/// own random secret, which the request path must carry; anything else is refused before the
/// WebSocket opens, as is any request from a web page (an `Origin` header) or for another host.
/// Accepted connections share the pipe through `DevToolsMultiplexer`.
nonisolated final class DevToolsGate: Sendable {
  /// The log of the agent DevTools pieces. Never given a secret or a message's content.
  static let log = Logger(subsystem: "ai.omnigent.weblayer", category: "devtools")
  static let pathPrefix = "/devtools/browser/"
  /// Largest request head accepted before the request is refused.
  static let maximumHeadBytes = 16 * 1024
  /// Largest message an agent may send.
  static let maximumMessageBytes = 64 * 1024 * 1024

  private struct State {
    var listener: NWListener?
    var port: UInt16?
    var startWaiters: [CheckedContinuation<Result<UInt16, WebLayerError>, Never>] = []
    var secrets: [String: String] = [:]
    var connections: [ObjectIdentifier: GateConnection] = [:]
    /// Bumped by every connection and idle check, so only the latest check may close.
    var idleGeneration = 0
    var closed = false
  }

  private let multiplexer: DevToolsMultiplexer
  private let idleTimeout: Duration
  private let queue = DispatchQueue(label: "ai.omnigent.weblayer.devtools-gate")
  private let state = Mutex(State())

  /// Creates a gate. Nothing listens until `endpoint(scope:)`.
  /// - Parameters:
  ///   - multiplexer: The pipe's multiplexer.
  ///   - idleTimeout: How long the gate stays open with no connection.
  init(multiplexer: DevToolsMultiplexer, idleTimeout: Duration = .seconds(60)) {
    self.multiplexer = multiplexer
    self.idleTimeout = idleTimeout
  }

  /// Whether the gate is listening.
  var isListening: Bool { state.withLock { $0.listener != nil } }

  /// How many WebSocket connections are open.
  var connectionCount: Int { state.withLock { $0.connections.count } }

  /// Opens the gate if needed and returns `scope`'s endpoint. A scope keeps its secret while the
  /// gate stays open.
  /// - Throws: `.devToolsFailed` when no loopback port can be opened.
  func endpoint(scope: String) async throws(WebLayerError) -> AgentDevToolsEndpoint {
    let port = try await listen().get()
    let secret = state.withLock { state in
      if let existing = state.secrets.first(where: { $0.value == scope })?.key { return existing }
      let fresh = Self.randomSecret()
      state.secrets[fresh] = scope
      return fresh
    }
    scheduleIdleCheck()
    return AgentDevToolsEndpoint(port: Int(port), path: Self.pathPrefix + secret)
  }

  /// Stops listening, closes every connection and forgets every secret.
  func close() {
    let closing = state.withLock { state in
      let open = state
      state = State(idleGeneration: state.idleGeneration + 1, closed: state.closed)
      return open
    }
    closing.listener?.cancel()
    for connection in closing.connections.values { connection.cancel() }
    for waiter in closing.startWaiters {
      waiter.resume(returning: .failure(Self.failure("The gate closed while opening.")))
    }
  }

  /// Closes the gate for good, when the browser behind it is gone.
  func shutDown() {
    state.withLock { $0.closed = true }
    close()
  }

  /// The scope a request path's secret opens, if any. Compares in constant time.
  func scope(forPath path: String) -> String? {
    guard path.hasPrefix(Self.pathPrefix) else { return nil }
    let offered = Data(path.dropFirst(Self.pathPrefix.count).utf8)
    return state.withLock { state in
      var match: String?
      for (secret, scope) in state.secrets
      where Self.constantTimeEqual(Data(secret.utf8), offered) {
        match = scope
      }
      return match
    }
  }

  // MARK: Listener

  private func listen() async -> Result<UInt16, WebLayerError> {
    await withCheckedContinuation { continuation in
      let action = state.withLock { state -> ListenAction in
        if state.closed { return .fail }
        if let port = state.port { return .ready(port) }
        state.startWaiters.append(continuation)
        return state.listener == nil ? .start : .wait
      }
      switch action {
      case .fail:
        continuation.resume(returning: .failure(Self.failure("The browser has exited.")))
      case .ready(let port):
        continuation.resume(returning: .success(port))
      case .wait:
        break
      case .start:
        startListener()
      }
    }
  }

  private enum ListenAction {
    case fail
    case ready(UInt16)
    case wait, start
  }

  private func startListener() {
    let parameters = NWParameters.tcp
    parameters.acceptLocalOnly = true
    parameters.requiredInterfaceType = .loopback
    let listener: NWListener
    do {
      listener = try NWListener(using: parameters, on: .any)
    } catch {
      finishStart(.failure(Self.failure("No loopback port: \(error)")))
      return
    }
    state.withLock { $0.listener = listener }
    listener.stateUpdateHandler = { [weak self, weak listener] newState in
      guard let self else { return }
      switch newState {
      case .ready:
        if let port = listener?.port?.rawValue {
          state.withLock { $0.port = port }
          finishStart(.success(port))
        } else {
          finishStart(.failure(Self.failure("The listener reported no port.")))
          close()
        }
      case .failed(let error):
        Self.log.error("The DevTools gate failed: \(error.localizedDescription)")
        finishStart(.failure(Self.failure("The listener failed: \(error)")))
        close()
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    listener.start(queue: queue)
  }

  private func finishStart(_ result: Result<UInt16, WebLayerError>) {
    let waiters = state.withLock { state in
      defer { state.startWaiters = [] }
      return state.startWaiters
    }
    for waiter in waiters { waiter.resume(returning: result) }
  }

  private func accept(_ connection: NWConnection) {
    let gateConnection = GateConnection(
      connection: connection, multiplexer: multiplexer,
      scopeForPath: { [weak self] path in self?.scope(forPath: path) })
    let key = ObjectIdentifier(gateConnection)
    state.withLock { state in
      state.connections[key] = gateConnection
      state.idleGeneration += 1
    }
    gateConnection.start(queue: queue) { [weak self] in
      guard let self else { return }
      let empty = state.withLock { state in
        state.connections[key] = nil
        return state.connections.isEmpty
      }
      if empty { scheduleIdleCheck() }
    }
  }

  private func scheduleIdleCheck() {
    let generation = state.withLock { state in
      state.idleGeneration += 1
      return state.idleGeneration
    }
    let seconds =
      Double(idleTimeout.components.seconds) + Double(idleTimeout.components.attoseconds) / 1e18
    queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
      guard let self else { return }
      let idle = state.withLock { state in
        state.idleGeneration == generation && state.connections.isEmpty && state.listener != nil
      }
      guard idle else { return }
      Self.log.info("The DevTools gate closes: no agent used it for a while.")
      close()
    }
  }

  // MARK: Helpers

  static func randomSecret() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator).hexByte }.joined()
  }

  static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for (leftByte, rightByte) in zip(left, right) { difference |= leftByte ^ rightByte }
    return difference == 0
  }

  static func failure(_ message: String) -> WebLayerError {
    .devToolsFailed(method: "gate", message: message)
  }
}
