public import SwiftUI

/// Which control answers Command-Return in a conversation. Exactly one owns it at a time, and
/// only the owner shows the hint.
///
/// A draft that can be sent keeps Command-Return on Send, so typing a reply while a request
/// waits never approves it by accident. With nothing to send, the request's Approve takes it on
/// whichever surface answers that request (inline or docked). ``ConversationScreen`` arbitrates; outside it (a lone dock or composer) the environment
/// value is `nil` and each keeps its own shortcut.
nonisolated public enum CommandReturnOwner: Hashable, Sendable {
  /// The composer's Send (and the Conversation menu's Send Message).
  case send
  /// A request's Approve, inline or docked.
  case approve

  /// The owner.
  /// - Parameters:
  ///   - canSend: The draft (or its attachments) can be sent now.
  ///   - approvableCardID: The request whose Approve would take the shortcut, if any.
  /// - Returns: The one owner.
  public static func resolve(canSend: Bool, approvableCardID: String?) -> Self {
    if canSend || approvableCardID == nil { return .send }
    return .approve
  }
}

extension EnvironmentValues {
  /// Set by ``ConversationScreen``; `nil` leaves Send and Approve each with their own shortcut.
  @Entry public var commandReturnOwner: CommandReturnOwner?
}

/// The dock's candidate for Command-Return (its ``DecisionDockModel/shortcutTarget``), inline or
/// docked, reported up to the screen that arbitrates.
struct ApproveShortcutCandidate: PreferenceKey {
  static let defaultValue: DecisionShortcutTarget? = nil

  static func reduce(
    value: inout DecisionShortcutTarget?, nextValue: () -> DecisionShortcutTarget?
  ) {
    value = value ?? nextValue()
  }
}
