public import Foundation

/// What to run: an executable, its full argument list, environment and working directory.
nonisolated public struct LocalProcessLaunch: Equatable, Sendable {
  /// Absolute path of the executable.
  public var executable: URL
  /// Arguments after `argv[0]`.
  public var arguments: [String]
  /// The complete environment; nothing else is inherited.
  public var environment: [String: String]
  /// The child's working directory.
  public var workingDirectory: URL?

  /// Creates a launch description.
  /// - Parameters:
  ///   - executable: Absolute executable path.
  ///   - arguments: Arguments after `argv[0]`.
  ///   - environment: The complete environment.
  ///   - workingDirectory: The working directory, or `nil` for the app's.
  public init(
    executable: URL, arguments: [String], environment: [String: String],
    workingDirectory: URL? = nil
  ) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
  }

  /// The command line for logs, without the environment.
  public var commandLine: String {
    ([executable.path] + arguments).map { $0.contains(" ") ? "'\($0)'" : $0 }
      .joined(separator: " ")
  }
}

/// A chunk of a child's output.
nonisolated public struct LocalProcessOutput: Equatable, Sendable {
  /// Which pipe it came from.
  public enum Stream: Equatable, Sendable {
    /// Standard output.
    case standardOutput
    /// Standard error.
    case standardError
  }

  /// The pipe.
  public var stream: Stream
  /// Raw bytes as read; lines may span chunks.
  public var data: Data

  /// Creates a chunk.
  /// - Parameters:
  ///   - stream: The pipe.
  ///   - data: The bytes.
  public init(_ stream: Stream, _ data: Data) {
    self.stream = stream
    self.data = data
  }
}

/// Signals the manager sends.
nonisolated public enum LocalProcessSignal: Equatable, Sendable {
  /// `SIGINT`, as Control-C in Terminal. The CLI's graceful path: a foreground
  /// `omnigent server` clears its pidfile only when stopped this way, because uvicorn re-raises
  /// SIGTERM after shutdown and skips the cleanup.
  case interrupt
  /// `SIGTERM`: shut down gracefully.
  case terminate
  /// `SIGKILL`: stop now.
  case kill

  var rawValue: Int32 {
    switch self {
    case .interrupt: SIGINT
    case .terminate: SIGTERM
    case .kill: SIGKILL
    }
  }
}

/// Identifies one process across PID reuse: the PID and when it started.
nonisolated public struct LocalProcessIdentity: Codable, Equatable, Sendable {
  /// The PID.
  public var pid: Int32
  /// Start time in microseconds since 1970, from the kernel.
  public var startMicroseconds: Int64

  /// Creates an identity.
  /// - Parameters:
  ///   - pid: The PID.
  ///   - startMicroseconds: Kernel start time.
  public init(pid: Int32, startMicroseconds: Int64) {
    self.pid = pid
    self.startMicroseconds = startMicroseconds
  }
}

/// A child the app spawned.
nonisolated public protocol LocalProcessHandle: AnyObject, Sendable {
  /// Its PID, which is also its process group ID.
  var pid: Int32 { get }
  /// Output from both pipes until both close. Iterate it once.
  var output: AsyncStream<LocalProcessOutput> { get }
  /// Waits until the process exits and returns how. Safe to call more than once.
  /// - Returns: The exit.
  func waitForExit() async -> LocalProcessExit
  /// Signals the child's whole process group, so a wrapper such as `uv run` and the server it
  /// started both receive it. Does nothing once the child has exited, so a reused PID is never
  /// signaled.
  /// - Parameter signal: The signal.
  /// - Throws: `LocalServerError.commandFailed` when the kernel refuses.
  func send(_ signal: LocalProcessSignal) throws(LocalServerError)
}

/// The OS operations the manager needs, behind a protocol so tests can script them.
nonisolated public protocol LocalProcessRunning: Sendable {
  /// Spawns a process in its own process group with both output pipes captured.
  /// - Parameter launch: What to run.
  /// - Returns: The running child.
  /// - Throws: `LocalServerError.spawnFailed` or `.spawnSetupFailed`.
  func launch(_ launch: LocalProcessLaunch) throws(LocalServerError) -> any LocalProcessHandle
  /// The identity of a running process, or `nil` when no such process exists.
  /// - Parameter pid: The PID.
  /// - Returns: Its identity.
  func identity(of pid: Int32) -> LocalProcessIdentity?
  /// Returns once a process the app did not spawn exits.
  /// - Parameter pid: The PID.
  func waitForExit(ofUnrelated pid: Int32) async
  /// Signals the process group led by `pid`, falling back to the process alone when it does not
  /// lead a group.
  /// - Parameters:
  ///   - signal: The signal.
  ///   - pid: The PID.
  /// - Throws: `LocalServerError.commandFailed` when the kernel refuses.
  func send(_ signal: LocalProcessSignal, toGroupOf pid: Int32) throws(LocalServerError)
  /// Whether `127.0.0.1:port` can be bound now.
  /// - Parameter port: The TCP port.
  /// - Returns: `true` when free.
  /// - Throws: `LocalServerError.spawnSetupFailed` when no socket could be created to check.
  func isLoopbackPortAvailable(_ port: Int) throws(LocalServerError) -> Bool
}

/// Time for polling and backoff, behind a protocol so tests run instantly.
nonisolated public protocol LocalServerClock: Sendable {
  /// The current instant.
  var now: ContinuousClock.Instant { get }
  /// Sleeps.
  /// - Parameter duration: How long.
  /// - Throws: `CancellationError` when the task is cancelled.
  func sleep(for duration: Duration) async throws
}

/// The real clock.
nonisolated public struct SystemLocalServerClock: LocalServerClock {
  /// Creates the clock.
  public init() {}

  /// The current instant.
  public var now: ContinuousClock.Instant { ContinuousClock.now }

  /// Sleeps on the continuous clock.
  /// - Parameter duration: How long.
  /// - Throws: `CancellationError` when the task is cancelled.
  public func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }
}
