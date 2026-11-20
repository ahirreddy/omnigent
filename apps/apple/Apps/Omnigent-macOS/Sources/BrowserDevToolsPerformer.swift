import Foundation
import OmnigentAppBrowser
import OmnigentBrowser
import OmnigentCoreFFI
import OmnigentStores

/// Answers the agent DevTools proxy's directory requests (`browser.devtools_request`, claimed
/// as `devtools.<op>` actions) about this app's Chromium: its loopback DevTools port, the
/// session's browser tabs with their targets, new background tabs for the agent, closing them,
/// and the agent's state for each tab's badge and strip. The server lets only the session
/// owner's clients claim these requests, and never for sessions shared with other editors.
///
/// Chromium's raw DevTools port is never opened: any local process could attach to it and read
/// every signed-in site's cookies. `attach` refuses until the app serves an access-gated
/// endpoint, so the runner falls back to its own browser.
final class BrowserDevToolsPerformer: BrowserActionPerforming {
  private let tabs: BrowserTabHost
  private let settings: BrowserSettings
  private weak var connection: ConnectionStore?

  /// Creates a performer.
  /// - Parameters:
  ///   - tabs: The app's browser tabs.
  ///   - settings: The browser settings, for the user's agent browsing switch.
  ///   - connection: The server connection whose sessions' turns Stop interrupts.
  init(tabs: BrowserTabHost, settings: BrowserSettings, connection: ConnectionStore?) {
    self.tabs = tabs
    self.settings = settings
    self.connection = connection
  }

  /// Runs one directory request and returns its result object as JSON. A refused request is a
  /// result with `ok: false`; only malformed requests throw.
  func perform(_ request: BrowserActionRequest) async throws -> Data {
    let operation = String(request.action.dropFirst(BrowserActionStore.devToolsActionPrefix.count))
    let args = try Self.arguments(request.argsJson)
    guard settings.agentDevTools else {
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
        reply = DevToolsRefusal(
          error: "endpoint_unavailable",
          message: "This Mac's browser has no access-gated DevTools endpoint yet.")
      case "tabs.list":
        reply = DevToolsReply(
          data: DevToolsListing(tabs: await tabs.devToolsTabs(sessionID: sessionID)))
      case "tabs.create":
        let url = (args["url"] as? String).flatMap(URL.init(string:))
        reply = DevToolsReply(
          data: try await tabs.openDevToolsTab(
            sessionID: sessionID, url: url, stopTurn: stopTurn(sessionID)))
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

private struct DevToolsEmpty: Encodable {}
