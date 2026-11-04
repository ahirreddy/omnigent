import Foundation

/// What the sidebar selects; the detail column shows it.
nonisolated public enum SidebarDestination: Hashable, Sendable {
  /// The new-session page ("What should we work on?").
  case newSession
  /// The Inbox.
  case inbox
  /// The Canvas.
  case canvas
  /// Automations (scheduled tasks).
  case automations
  /// Usage and spend.
  case usage
  /// A session.
  case session(String)

  /// The selected session id, if a session is selected.
  public var sessionID: String? {
    if case .session(let id) = self { return id }
    return nil
  }
}
