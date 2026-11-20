import Foundation

/// What the sidebar selects; the detail column shows it.
nonisolated public enum SidebarDestination: Hashable, Sendable {
  /// The new-session page ("What should we build?").
  case newSession
  /// The Inbox.
  case inbox
  /// The Canvas.
  case canvas
  /// Automations (scheduled tasks).
  case automations
  /// Saved workflows.
  case workflows
  /// Usage and spend.
  case usage
  /// An extension's page, by the extension and the page's route.
  case extensionPage(extensionID: String, route: String)
  /// A project's board, by its folder id (``SessionProject/id``).
  case project(String)
  /// A session.
  case session(String)
  /// The new-session page adding a nested agent beside a session ("Add nested agent").
  case nestedSession(sourceID: String)

  /// The selected session id, if a session is selected.
  public var sessionID: String? {
    if case .session(let id) = self { return id }
    return nil
  }

  /// The project whose board is shown, by its folder id.
  public var projectID: String? {
    if case .project(let id) = self { return id }
    return nil
  }
}
