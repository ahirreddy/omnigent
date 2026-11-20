import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// New automations from a session row: the menu item and which sessions offer it.
extension AutomationsAdapter {
  /// Opens a new automation from a session row, where the server starts runs from a copy of
  /// a session; `nil` hides the menu item.
  /// - Parameters:
  ///   - connection: The server.
  ///   - show: Shows the Automations page.
  /// - Returns: The row action.
  @MainActor
  static func createFromSession(
    _ connection: ConnectionStore, show: @escaping @MainActor () -> Void
  )
    -> (@MainActor (OmnigentUIComponents.SessionSummary) -> Void)?
  {
    guard let pages = connection.pages, let offered = pages.offered, offered.automations,
      offered.automationSourceSessions
    else { return nil }
    let list = connection.sessionList
    return { summary in
      let session = list.sessionsByID[summary.id]
      let configuration = session?.configuration
      pages.requestAutomation(
        from: AutomationSource(
          sessionID: summary.id, title: summary.title, agentID: configuration?.agentId,
          hostID: configuration?.hostId,
          workspace: session.map(\.workspace).flatMap { $0.isEmpty ? nil : $0 },
          model: configuration?.modelOverride, effort: configuration?.effort))
      show()
    }
  }

  /// Whether a session can be an automation's source (web `canCreateAutomationFromSession`):
  /// a listed session with an agent that no automation runs from yet. Side chats are never
  /// listed, and the menus leave out shared and archived sessions.
  static func offersAutomation(from session: OmnigentCoreFFI.SessionSummary?) -> Bool {
    guard let session, session.automationSourceId == nil else { return false }
    return session.configuration?.agentId?.isEmpty == false
  }
}
