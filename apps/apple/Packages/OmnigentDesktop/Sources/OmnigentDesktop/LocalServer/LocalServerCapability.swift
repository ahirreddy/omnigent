public import Foundation

/// Whether this build may run the `omnigent` CLI as a child process.
///
/// The Developer ID edition (`OmnigentMac`) can. The Mac App Store edition runs in App Sandbox,
/// where a child process inherits the sandbox and cannot reach the user's CLI install, its
/// `~/.omnigent` data or the agent tools host mode needs. That edition passes `.unavailable` and
/// every local-server surface shows `explanation` instead of controls.
nonisolated public enum LocalServerCapability: Equatable, Sendable {
  /// Starting, adopting and stopping local processes is allowed.
  case available
  /// Local processes are off for this build.
  case unavailable(LocalServerUnavailableReason)

  /// `.unavailable(.appSandbox)` inside App Sandbox, otherwise `.available`.
  ///
  /// The app should pass its edition's capability explicitly; this is the fallback for code that
  /// has no edition, such as the example app and tests.
  /// - Parameter environment: Normally `ProcessInfo.processInfo.environment`.
  /// - Returns: The capability.
  public static func detect(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    // macOS sets this variable for every process launched inside App Sandbox.
    environment["APP_SANDBOX_CONTAINER_ID"] == nil ? .available : .unavailable(.appSandbox)
  }

  /// Whether processes may be spawned.
  public var isAvailable: Bool { self == .available }
}

/// Why local processes are off.
nonisolated public enum LocalServerUnavailableReason: Equatable, Sendable {
  /// The Mac App Store edition runs in App Sandbox.
  case appSandbox
  /// Turned off for another reason, such as an organization policy.
  case disabled(String)

  /// A sentence or two for Settings and the menu bar.
  public var explanation: String {
    switch self {
    case .appSandbox:
      "This edition of Omnigent comes from the Mac App Store and runs in App Sandbox, so it "
        + "cannot run the omnigent command-line tool. Start a server in Terminal with "
        + "`omnigent server`, then connect to it, or use the Developer ID edition of Omnigent "
        + "to manage a server from the app."
    case .disabled(let reason): reason
    }
  }
}
