import Foundation
import Observation
import OmnigentUIComponents

/// A chat's Chat or Terminal choice, kept by its window so it outlasts the chat's view. Each
/// chat observes its own, so one chat's switch re-renders only that chat.
@Observable
final class SessionViewChoice {
  /// The choice; `nil` until the chat first shows its terminal view or the user chooses.
  var mode: SessionViewMode?
}

extension SessionTabGroups {
  /// A session's Chat or Terminal choice, for the window's life.
  /// - Parameter sessionID: The session (a side chat's own session for a side chat).
  /// - Returns: The choice.
  func viewChoice(_ sessionID: String) -> SessionViewChoice {
    if let choice = viewChoices[sessionID] { return choice }
    let choice = SessionViewChoice()
    viewChoices[sessionID] = choice
    return choice
  }

  /// Whether a session's chat shows its transcript or its agent's terminal.
  /// - Parameter sessionID: The session.
  /// - Returns: The mode; Chat until something chose.
  func viewMode(_ sessionID: String) -> SessionViewMode {
    viewChoice(sessionID).mode ?? .chat
  }

  /// Shows a session's chat as its transcript or its agent's terminal.
  /// - Parameters:
  ///   - mode: Chat or Terminal.
  ///   - sessionID: The session.
  func setViewMode(_ mode: SessionViewMode, for sessionID: String) {
    let choice = viewChoice(sessionID)
    if choice.mode != mode { choice.mode = mode }
  }

  /// Whether saved tabs were left on the agent's terminal, from when it had a tab of its own.
  nonisolated static func selectsHarness(_ snapshot: TabWindowSnapshot) -> Bool {
    snapshot.tabs.contains { $0.id == snapshot.selectedID && $0.content.kind == .agentTerminal }
  }
}
