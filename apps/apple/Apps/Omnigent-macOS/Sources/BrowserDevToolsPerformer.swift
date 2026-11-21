import Foundation
import OSLog
import OmnigentAppBrowser
import OmnigentBrowser
import OmnigentCoreFFI
import OmnigentStores

/// Answers the agent DevTools proxy's directory requests (`browser.devtools_request`, claimed
/// as `devtools.<op>` actions) about this app's Chromium: the endpoint to connect to, the
/// session's browser tabs with their targets, new background tabs for the agent, closing them,
/// and the agent's state for each tab's badge and strip. The server lets only the session
/// owner's clients claim these requests, and never for sessions shared with other editors.
///
/// Chromium never opens a DevTools port. `attach` opens the app's loopback gate in front of a
/// DevTools pipe only the app holds, and answers with a path that carries this session's
/// secret; the gate shows the session only its own tabs. It opens only while the server offers
/// `agent_browser_devtools` and the user's setting is on.
final class BrowserDevToolsPerformer: BrowserActionPerforming {
  private static let logger = Logger(subsystem: "ai.omnigent.mac", category: "agent-devtools")
  private let tabs: BrowserTabHost
  private let settings: BrowserSettings
  private weak var connection: ConnectionStore?
  private let gate: () throws(BrowserError) -> (any BrowserAgentDevToolsGate)?

  /// Creates a performer.
  /// - Parameters:
  ///   - tabs: The app's browser tabs.
  ///   - settings: The browser settings, for the user's agent browsing switch.
  ///   - connection: The server connection whose sessions' turns Stop interrupts.
  ///   - gate: The engine behind the gate, started on first use; `nil` without Chromium.
  init(
    tabs: BrowserTabHost, settings: BrowserSettings, connection: ConnectionStore?,
    gate: @escaping () throws(BrowserError) -> (any BrowserAgentDevToolsGate)?
  ) {
    self.tabs = tabs
    self.settings = settings
    self.connection = connection
    self.gate = gate
  }

  /// Runs one directory request and returns its result object as JSON. A refused request is a
  /// result with `ok: false`; only malformed requests throw.
  func perform(_ request: BrowserActionRequest) async throws -> Data {
    let operation = String(request.action.dropFirst(BrowserActionStore.devToolsActionPrefix.count))
    let args = try Self.arguments(request.argsJson)
    guard settings.agentDevTools else {
      closeGate()
      return try Self.encode(
        DevToolsRefusal(
          error: "agent_browsing_off",
          message: "Agent browsing is turned off in this Mac's browser settings."))
    }
    let sessionID = request.sessionId
    let reply: any Encodable
    do throws(BrowserError) {
      switch operation {
      case "attach":
        reply = try await attach(sessionID)
      case "tabs.list":
        let listing = await tabs.devToolsTabs(sessionID: sessionID)
        try gate()?.setAgentDevToolsScope(sessionID, targets: Set(listing.map(\.targetID)))
        reply = DevToolsReply(data: DevToolsListing(tabs: listing))
      case "tabs.create":
        let url = (args["url"] as? String).flatMap(URL.init(string:))
        let tab = try await tabs.openDevToolsTab(
          sessionID: sessionID, url: url, stopTurn: stopTurn(sessionID))
        try gate()?.addAgentDevToolsTarget(tab.targetID, scope: sessionID)
        reply = DevToolsReply(data: tab)
      case "tabs.close":
        try tabs.closeDevToolsTab(sessionID: sessionID, targetID: Self.target(args))
        reply = DevToolsReply(data: DevToolsEmpty())
      case "tabs.agent_state":
        try tabs.setDevToolsAgentState(
          sessionID: sessionID, targetID: Self.target(args),
          state: args["state"] as? String ?? "", stopTurn: stopTurn(sessionID))
        reply = DevToolsReply(data: DevToolsEmpty())
      default:
        reply = DevToolsRefusal(
          error: "unknown_op", message: "This app does not know \(operation).")
      }
    } catch {
      reply = DevToolsRefusal(error: "browser_error", message: String(describing: error))
    }
    return try Self.encode(reply)
  }

  /// Opens the gate for `sessionID` once the server offers agent browsing, scoped to the
  /// session's current tabs.
  private func attach(_ sessionID: String) async throws(BrowserError) -> any Encodable {
    guard let core = connection?.core else {
      return DevToolsRefusal(
        error: "not_connected", message: "The app has no server connection.")
    }
    do {
      guard try await core.panelFeatures().agentBrowserDevtools else {
        return DevToolsRefusal(
          error: "feature_off", message: "The server does not offer agent browsing.")
      }
    } catch {
      return DevToolsRefusal(
        error: "server_error",
        message: "The app could not read the server's features: \(error.localizedDescription)")
    }
    guard let gate = try gate() else {
      return DevToolsRefusal(
        error: "endpoint_unavailable", message: "This Mac's browser has no agent DevTools.")
    }
    let listing = await tabs.devToolsTabs(sessionID: sessionID)
    gate.setAgentDevToolsScope(sessionID, targets: Set(listing.map(\.targetID)))
    let endpoint = try await gate.agentDevToolsEndpoint(scope: sessionID)
    return DevToolsReply(data: DevToolsAttach(port: endpoint.port, path: endpoint.path))
  }

  /// Closes the gate once the user turned agent browsing off.
  private func closeGate() {
    do throws(BrowserError) {
      try gate()?.closeAgentDevToolsEndpoint()
    } catch {
      Self.logger.error(
        "The agent DevTools gate could not be closed: \(String(describing: error), privacy: .public)"
      )
    }
  }

  /// Interrupts the session's turn, for the agent strip's Stop.
  private func stopTurn(_ sessionID: String) -> @MainActor () -> Void {
    { [weak connection] in
      guard let conversation = connection?.conversation(sessionID) else { return }
      Task { await conversation.interrupt() }
    }
  }

  private static func arguments(_ json: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    else { throw BrowserError.agentActionFailed("The request's arguments are not an object.") }
    return object
  }

  private static func target(_ args: [String: Any]) throws(BrowserError) -> String {
    guard let target = args["target_id"] as? String, !target.isEmpty else {
      throw .agentActionFailed("The request names no target_id.")
    }
    return target
  }

  private static func encode(_ value: some Encodable) throws -> Data {
    try JSONEncoder().encode(value)
  }
}

private struct DevToolsReply<Payload: Encodable>: Encodable {
  var ok = true
  let data: Payload
}

private struct DevToolsRefusal: Encodable {
  var ok = false
  let error: String
  let message: String
}

private struct DevToolsListing: Encodable {
  let tabs: [BrowserDevToolsTab]
}

/// The gate's address; `path` holds the session's secret.
private struct DevToolsAttach: Encodable {
  let port: Int
  let path: String
}

private struct DevToolsEmpty: Encodable {}
