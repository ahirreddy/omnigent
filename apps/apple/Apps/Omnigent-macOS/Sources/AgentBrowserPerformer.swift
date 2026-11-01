import Foundation
import OmnigentBrowser
import OmnigentCoreFFI
import OmnigentStores

/// Runs the agent browser actions this app claimed (`BrowserActionStore`) in the edition's
/// agent browser: Chromium in the Developer ID edition. The App Store edition has no engine
/// that supports agent actions, so it installs no performer and leaves actions unclaimed for
/// another client.
final class AgentBrowserPerformer: BrowserActionPerforming {
  private let controller: any AgentBrowserActing

  /// Creates a performer over `controller`.
  /// - Parameter controller: The agent browser.
  init(controller: any AgentBrowserActing) {
    self.controller = controller
  }

  /// The agent browser, for read-only agent tabs.
  var agentController: AgentBrowserController? { controller as? AgentBrowserController }

  /// The edition's performer, or `nil` where no engine runs agent actions.
  /// - Parameter provider: The edition's engines.
  /// - Returns: The performer.
  static func forEdition(provider: DefaultBrowserEngineProvider) -> AgentBrowserPerformer? {
    #if OMNIGENT_CHROMIUM
      AgentBrowserPerformer(
        controller: AgentBrowserController(provider: provider, engine: .chromium))
    #else
      nil
    #endif
  }

  /// Runs `request` and returns its `result` object as JSON. A failed action is a result with
  /// `ok: false`, not a thrown error; only malformed requests or results throw.
  func perform(_ request: BrowserActionRequest) async throws -> Data {
    let action = try AgentBrowserActionRequest(
      eventJSON: try request.eventJSON(), conversationID: request.sessionId)
    return try await controller.perform(action).jsonData()
  }
}
