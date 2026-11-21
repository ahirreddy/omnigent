internal import Foundation
internal import Synchronization

/// Agents' DevTools access to one running host: Chromium's pipe, the multiplexer that shares it,
/// and the loopback gate in front. Lives as long as the host process.
nonisolated final class DevToolsBridge: Sendable {
  let pipe: DevToolsPipe
  let multiplexer: DevToolsMultiplexer
  let gate: DevToolsGate
  private let discovering = Mutex(false)

  init(pipe: DevToolsPipe, idleTimeout: Duration) {
    self.pipe = pipe
    let multiplexer = DevToolsMultiplexer { [weak pipe] message in pipe?.send(message) }
    self.multiplexer = multiplexer
    gate = DevToolsGate(multiplexer: multiplexer, idleTimeout: idleTimeout)
  }

  /// Reads the pipe; the gate shuts when the host's end closes.
  func startReading() {
    pipe.start(
      onMessage: { [multiplexer] message in multiplexer.upstreamMessage(message) },
      onClose: { [multiplexer, gate] in
        gate.shutDown()
        multiplexer.upstreamClosed()
      })
  }

  /// Opens the gate if needed and returns `scope`'s endpoint.
  func endpoint(scope: String) async throws(WebLayerError) -> AgentDevToolsEndpoint {
    let first = discovering.withLock { started in
      defer { started = true }
      return !started
    }
    if first { multiplexer.start() }
    return try await gate.endpoint(scope: scope)
  }

  func shutDown() {
    gate.shutDown()
    multiplexer.upstreamClosed()
    pipe.shutDown()
  }
}

/// Agent DevTools: a loopback endpoint the app opens only on request, behind per-scope secrets.
extension Session {
  /// The host's DevTools pipe when `configuration.agentDevTools` is on, with its switch added
  /// to `arguments`.
  func makeDevToolsPipe(arguments: inout [String]) throws(WebLayerError) -> DevToolsPipe? {
    guard configuration.agentDevTools else { return nil }
    let pipe = try DevToolsPipe()
    arguments.append("--owl-devtools-pipe")
    return pipe
  }

  /// Starts serving `pipe` once the host holds its ends.
  func adoptDevToolsPipe(_ pipe: DevToolsPipe?) {
    guard let pipe else { return }
    pipe.closeChildEnds()
    let bridge = DevToolsBridge(pipe: pipe, idleTimeout: configuration.agentDevToolsIdleTimeout)
    bridge.startReading()
    devTools = bridge
  }

  /// Opens the agent DevTools gate if needed and returns `scope`'s endpoint. The endpoint's path
  /// holds a secret: hand it only to `scope`'s owner and never log it.
  /// - Parameter scope: Whose tabs the connection may use, e.g. an Omnigent session id.
  /// - Returns: The endpoint.
  /// - Throws: `.notReady` before Chromium runs, `.devToolsFailed` when this session was started
  ///   without `agentDevTools` or no loopback port can be opened.
  public func agentDevToolsEndpoint(scope: String) async throws(WebLayerError)
    -> AgentDevToolsEndpoint
  {
    guard isReady else { throw .notReady }
    guard let devTools else {
      throw .devToolsFailed(method: "gate", message: "This browser runs without agent DevTools.")
    }
    return try await devTools.endpoint(scope: scope)
  }

  /// Sets the targets `scope`'s connections may use: its tabs' DevTools target ids.
  public func setAgentDevToolsScope(_ scope: String, targets: Set<String>) {
    devTools?.multiplexer.setScope(scope, targets: targets)
  }

  /// Lets `scope`'s connections use one more target, e.g. a tab just opened for its agent.
  public func addAgentDevToolsTarget(_ target: String, scope: String) {
    devTools?.multiplexer.addToScope(scope, target: target)
  }

  /// Closes the gate and its connections now, e.g. when the user turns agent browsing off.
  public func closeAgentDevToolsEndpoint() {
    devTools?.gate.close()
  }

  /// Whether the agent DevTools gate is listening.
  public var isAgentDevToolsListening: Bool {
    devTools?.gate.isListening ?? false
  }
}
