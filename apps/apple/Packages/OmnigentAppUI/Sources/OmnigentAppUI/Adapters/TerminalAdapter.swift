import OmnigentCoreFFI
import OmnigentUIComponents

/// Maps the core's terminal records onto the components' states.
enum TerminalAdapter {
  /// The session header's Chat/Terminal state from the core's harness terminal.
  /// - Parameter harness: `SessionTerminalsStore.harness`.
  /// - Returns: The status; `unavailable` offers "Resume sandbox".
  static func status(_ harness: HarnessTerminal) -> OmnigentUIComponents.TerminalStatus {
    switch harness {
    case .notTerminalFirst: .none
    case .startingUp: .startingUp(stage: nil)
    case .unavailable: .sandboxOffline
    case .ready: .ready
    }
  }
}
