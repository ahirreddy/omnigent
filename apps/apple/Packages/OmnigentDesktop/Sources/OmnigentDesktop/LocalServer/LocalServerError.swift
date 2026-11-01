public import Foundation

/// Every way managing a local server or host can fail. Each one is shown as state, never dropped.
nonisolated public enum LocalServerError: Error, Equatable, Sendable {
  /// No usable `omnigent` CLI was found. `searched` lists the places tried, in order.
  case cliNotFound(searched: [String])
  /// The CLI path set in Settings is missing or not executable.
  case configuredCLIInvalid(path: String)
  /// `posix_spawn` failed before the process ran.
  case spawnFailed(executable: String, errno: Int32)
  /// A pipe or file action could not be prepared for the child.
  case spawnSetupFailed(String)
  /// The fixed port in Settings is taken by another process.
  case portUnavailable(port: Int)
  /// The process exited before it reported ready.
  case exitedBeforeReady(LocalProcessExit, lastLines: [String])
  /// The process ran but never became ready in time.
  case readinessTimedOut(seconds: Int, lastProblem: String?)
  /// Something answered on the server's port that is not an Omnigent server.
  case notAnOmnigentServer(url: URL, detail: String)
  /// The app's record of the server it started could not be read or written.
  case recordFailed(String)
  /// A short CLI command (`server stop`, `host stop`) failed.
  case commandFailed(command: String, exit: LocalProcessExit?, output: String)
  /// Hosting needs a server URL: start the local server or open a server window first.
  case noServerForHost
  /// `omnigent host` could not sign in to the server non-interactively.
  case hostAuthenticationRequired(serverURL: URL, detail: String)
  /// The process crashed `attempts` times in a row and is no longer restarted.
  case restartLimitReached(attempts: Int, lastExit: LocalProcessExit)
  /// Local processes are off for this build.
  case unavailable(LocalServerUnavailableReason)

  /// One or two sentences for Settings, the menu bar and the issue log.
  public var message: String {
    switch self {
    case .cliNotFound(let searched):
      "The omnigent command-line tool was not found (looked in \(searched.count) places). "
        + LocalCLIDiscovery.installGuidance
    case .configuredCLIInvalid(let path):
      "The CLI path set in Settings, \(path), is not an executable file. Choose another file "
        + "or switch back to automatic detection."
    case .spawnFailed(let executable, let code):
      "Could not run \(executable): \(Errno.describe(code))."
    case .spawnSetupFailed(let detail): "Could not prepare the process: \(detail)."
    case .portUnavailable(let port):
      "Port \(port) is already in use. No process was stopped. Free the port or choose "
        + "Automatic in Settings."
    case .exitedBeforeReady(let exit, _): "The process \(exit.summary) before it was ready."
    case .readinessTimedOut(let seconds, let problem):
      "Not ready after \(seconds) seconds" + (problem.map { ": \($0)." } ?? ".")
    case .notAnOmnigentServer(let url, let detail):
      "\(url.absoluteString) is not an Omnigent server: \(detail)."
    case .recordFailed(let detail): "Could not update the local server record: \(detail)."
    case .commandFailed(let command, let exit, let output):
      "`\(command)` \(exit?.summary ?? "did not finish")"
        + (output.isEmpty ? "." : ": \(output)")
    case .noServerForHost:
      "Start the local server or open a window on a server before hosting on this Mac."
    case .hostAuthenticationRequired(let url, _):
      "Sign in first: run `omnigent login \(url.absoluteString)` in Terminal, then try again."
    case .restartLimitReached(let attempts, let exit):
      "Stopped restarting after \(attempts) crashes in a row (last \(exit.summary))."
    case .unavailable(let reason): reason.explanation
    }
  }
}

/// How a process ended.
nonisolated public enum LocalProcessExit: Equatable, Sendable {
  /// It called `exit` with this status.
  case exited(Int32)
  /// A signal ended it.
  case signaled(Int32)
  /// It ended, but `waitpid` could not report how. Used for processes the app did not spawn,
  /// whose status only their parent can collect.
  case unknown

  /// "exited with status 1", "was ended by signal 9 (Killed)".
  public var summary: String {
    switch self {
    case .exited(let status): "exited with status \(status)"
    case .signaled(let signal):
      "was ended by signal \(signal) (\(unsafe String(cString: strsignal(signal))))"
    case .unknown: "exited"
    }
  }

  /// Whether the exit was a clean `exit(0)`.
  public var isSuccess: Bool { self == .exited(0) }
}
