public import Observation
public import OmnigentCoreFFI

/// A started session's `/mcp` panel (the web composer's MCP server list): read while it shows,
/// read again as long as the core says a row is still settling, and a live server reconnected.
@Observable
public final class McpPanelStore {
  /// The session details the panel's sources depend on.
  struct Session: Equatable {
    var agentID: String?
    var harness: String?
    var hostID: String?

    init(_ settings: SessionSettings? = nil) {
      agentID = settings?.agentId
      harness = settings?.harness
      hostID = settings?.hostId
    }
  }

  /// A reconnect that did not leave its server connected.
  public struct ReconnectFailure: Hashable, Sendable {
    /// The harness's name for the server.
    public let name: String
    /// Why.
    public let message: String

    /// A failure.
    /// - Parameters:
    ///   - name: The server.
    ///   - message: Why.
    public init(name: String, message: String) {
      self.name = name
      self.message = message
    }
  }

  /// The panel, once read.
  public private(set) var panel: McpPanel?
  /// The harness's name of the server reconnecting now.
  public private(set) var reconnecting: String?
  /// The latest reconnect that failed, until the panel closes.
  public private(set) var reconnectFailure: ReconnectFailure?

  /// The session's agent, harness and routing host, read before each load.
  var session: (() -> Session)?
  private let sessionID: String
  private let core: ClientCore

  init(sessionID: String, core: ClientCore) {
    self.sessionID = sessionID
    self.core = core
  }

  /// Reads the panel, then again after each delay the core asks for, until cancelled when the
  /// panel closes; a reconnect failure doesn't outlive it.
  public func watch() async {
    reconnectFailure = nil
    defer { reconnectFailure = nil }
    while !Task.isCancelled {
      guard let delay = await load() else { return }
      try? await Task.sleep(for: .milliseconds(delay))
    }
  }

  /// Reconnects the live server `name`, then reads the panel again.
  /// - Parameter name: The harness's name for it.
  public func reconnect(_ name: String) async {
    guard reconnecting == nil else { return }
    reconnecting = name
    reconnectFailure = nil
    do {
      if let refusal = try await core.reconnectLiveMcpServer(sessionId: sessionID, name: name) {
        reconnectFailure = ReconnectFailure(name: name, message: refusal)
      }
    } catch {
      let message = coreError(error).message
      reconnectFailure = ReconnectFailure(
        name: name, message: message.isEmpty ? "Couldn\u{2019}t reconnect. Try again." : message)
    }
    await load()
    reconnecting = nil
  }

  /// Reads the panel once.
  /// - Returns: When to read it again, in milliseconds.
  @discardableResult
  func load() async -> UInt32? {
    let details = session?() ?? Session()
    do {
      panel = try await core.sessionMcpPanel(
        sessionId: sessionID, agentId: details.agentID, harness: details.harness,
        hostId: details.hostID)
    } catch {
      panel = McpPanel(rows: [], status: coreError(error).message, pollAfterMs: nil)
    }
    return panel?.pollAfterMs
  }
}
