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
final class BrowserDevToolsPerformer: BrowserActionPerforming {
  private let tabs: BrowserTabHost
  private let port: Int
  private let settings: BrowserSettings
  private weak var connection: ConnectionStore?
  /// How long a just-started web host may take to open its DevTools port.
  private static let portWait = Duration.seconds(10)

  /// Creates a performer.
  /// - Parameters:
  ///   - tabs: The app's browser tabs.
  ///   - port: Chromium's loopback DevTools port.
  ///   - settings: The browser settings, for the user's agent browsing switch.
  ///   - connection: The server connection whose sessions' turns Stop interrupts.
  init(tabs: BrowserTabHost, port: Int, settings: BrowserSettings, connection: ConnectionStore?) {
    self.tabs = tabs
    self.port = port
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
        reply = DevToolsReply(data: try await endpoint())
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

  /// Starts Chromium when no tab has yet, then reads which browser owns the DevTools port, so
  /// the runner can tell whether it shares this Mac.
  private func endpoint() async throws(BrowserError) -> DevToolsEndpoint {
    _ = try tabs.environment.provider.engine(for: .chromium)
    let deadline = ContinuousClock.now + Self.portWait
    var lastError = "no answer"
    while ContinuousClock.now < deadline {
      do {
        return DevToolsEndpoint(port: port, browserPath: try await Self.browserPath(port: port))
      } catch {
        lastError = String(describing: error)
      }
      do {
        try await Task.sleep(for: .milliseconds(200))
      } catch {
        throw .agentActionFailed("Cancelled while Chromium started.")
      }
    }
    throw .agentActionFailed("Chromium's DevTools port \(port) did not answer: \(lastError)")
  }

  private static func browserPath(port: Int) async throws -> String {
    guard let url = URL(string: "http://127.0.0.1:\(port)/json/version") else {
      throw BrowserError.invalidURL("127.0.0.1:\(port)")
    }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let (data, _) = try await session.data(from: url)
    struct Version: Decodable { let webSocketDebuggerUrl: String }
    let reported = try JSONDecoder().decode(Version.self, from: data).webSocketDebuggerUrl
    guard let path = URLComponents(string: reported)?.path, path.hasPrefix("/devtools/") else {
      throw BrowserError.agentActionFailed("Chromium reported no browser endpoint.")
    }
    return path
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

private struct DevToolsEndpoint: Encodable {
  let port: Int
  let browserPath: String

  enum CodingKeys: String, CodingKey {
    case port
    case browserPath = "browser_path"
  }
}

private struct DevToolsListing: Encodable {
  let tabs: [BrowserDevToolsTab]
}

private struct DevToolsEmpty: Encodable {}
