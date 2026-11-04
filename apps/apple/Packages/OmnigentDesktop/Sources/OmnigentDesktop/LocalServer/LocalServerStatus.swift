public import Foundation

/// Who started a process, which decides whether quitting the app stops it.
nonisolated public enum LocalServiceOwnership: Equatable, Sendable {
  /// This launch of the app spawned it.
  case owned
  /// An earlier launch spawned it and quit without stopping it (it crashed); found through the
  /// app's record, so this launch stops it on quit as if it had started it.
  case recovered
  /// Started outside the app, for example `omnigent server` in Terminal. Never stopped on quit.
  case adopted

  /// Whether the app stops it when it quits.
  public var stopsOnQuit: Bool { self != .adopted }

  /// "Started by Omnigent", "Started outside Omnigent".
  public var label: String {
    switch self {
    case .owned: "Started by Omnigent"
    case .recovered: "Started by Omnigent before it last quit"
    case .adopted: "Started outside Omnigent"
    }
  }
}

/// A ready local server.
nonisolated public struct LocalServerEndpoint: Equatable, Sendable {
  /// `http://127.0.0.1:<port>`.
  public var url: URL
  /// The TCP port.
  public var port: Int
  /// The server's PID when known.
  public var pid: Int32?
  /// What its manifest advertised; `nil` for servers older than the manifest route.
  public var manifest: LocalServerManifest?

  /// Creates an endpoint, or `nil` when `port` is outside 1...65535.
  /// - Parameters:
  ///   - port: The loopback port.
  ///   - pid: The PID.
  ///   - manifest: The manifest.
  public init?(port: Int, pid: Int32?, manifest: LocalServerManifest?) {
    guard let url = Self.loopbackURL(port: port) else { return nil }
    self.url = url
    self.port = port
    self.pid = pid
    self.manifest = manifest
  }

  /// `http://127.0.0.1:<port>`, the URL the CLI records and prints.
  /// - Parameter port: The port.
  /// - Returns: The URL, or `nil` when `port` is outside 1...65535.
  public static func loopbackURL(port: Int) -> URL? {
    guard (1...65_535).contains(port) else { return nil }
    var components = URLComponents()
    components.scheme = "http"
    components.host = "127.0.0.1"
    components.port = port
    return components.url
  }
}

/// Why the manager started a server, which decides whether the app offers to open a window.
nonisolated public enum LocalServerStartTrigger: Equatable, Sendable {
  /// The user chose Start Server.
  case user
  /// A window's "Get started locally", which connects that window itself.
  case window
  /// Settings > Local Server > Start when Omnigent opens.
  case launch
  /// An automatic restart after a crash.
  case restart(attempt: Int)
}

/// The local server's state.
nonisolated public enum LocalServerStatus: Equatable, Sendable {
  /// Local processes are off for this build.
  case unavailable(LocalServerUnavailableReason)
  /// Not running.
  case stopped
  /// Looking for the CLI or a server that is already running.
  case checking
  /// Spawned and waiting for `/health` and the manifest.
  case starting(LocalServerStartTrigger)
  /// Ready.
  case running(LocalServerEndpoint, LocalServiceOwnership)
  /// Stopping.
  case stopping
  /// It exited on its own. `restartAt` is set while a restart is scheduled.
  case crashed(LocalProcessExit, restartAt: Date?)
  /// Starting or stopping failed.
  case failed(LocalServerError)

  /// The endpoint while running.
  public var endpoint: LocalServerEndpoint? {
    if case .running(let endpoint, _) = self { return endpoint }
    return nil
  }

  /// Who started it, while running.
  public var ownership: LocalServiceOwnership? {
    if case .running(_, let ownership) = self { return ownership }
    return nil
  }

  /// Whether Start Server is meaningful now.
  public var canStart: Bool {
    switch self {
    case .stopped, .failed, .crashed(_, restartAt: nil): true
    default: false
    }
  }

  /// Whether Stop Server is meaningful now.
  public var canStop: Bool {
    switch self {
    case .running, .starting, .crashed(_, restartAt: .some): true
    default: false
    }
  }

  /// A short description for menus and Settings.
  public var summary: String {
    switch self {
    case .unavailable: "Unavailable in this edition"
    case .stopped: "Not running"
    case .checking: "Checking\u{2026}"
    case .starting(.restart(let attempt)): "Restarting (attempt \(attempt))\u{2026}"
    case .starting: "Starting\u{2026}"
    case .running(let endpoint, _): "Running at \(endpoint.url.absoluteString)"
    case .stopping: "Stopping\u{2026}"
    case .crashed(let exit, let restartAt):
      restartAt == nil ? "Crashed: \(exit.summary)" : "Crashed; restarting soon"
    case .failed(let error): error.message
    }
  }
}

/// The host connection's state: this Mac running agent work for a server.
nonisolated public enum LocalHostStatus: Equatable, Sendable {
  /// Local processes are off for this build.
  case unavailable(LocalServerUnavailableReason)
  /// Not hosting.
  case stopped
  /// Waiting for the user to allow host mode.
  case awaitingConfirmation(serverURL: URL)
  /// Spawned and waiting for `omnigent host` to report it connected.
  case connecting(serverURL: URL)
  /// Connected and taking work.
  case connected(serverURL: URL, LocalServiceOwnership)
  /// Stopping.
  case stopping
  /// It exited on its own. `restartAt` is set while a restart is scheduled.
  case crashed(serverURL: URL, LocalProcessExit, restartAt: Date?)
  /// Starting or stopping failed.
  case failed(LocalServerError)

  /// The server being hosted for, while connecting or connected.
  public var serverURL: URL? {
    switch self {
    case .awaitingConfirmation(let url), .connecting(let url), .connected(let url, _),
      .crashed(let url, _, _):
      url
    default: nil
    }
  }

  /// Whether Start Host is meaningful now.
  public var canStart: Bool {
    switch self {
    case .stopped, .failed, .crashed(_, _, restartAt: nil): true
    default: false
    }
  }

  /// Whether Stop Host is meaningful now.
  public var canStop: Bool {
    switch self {
    case .connecting, .connected, .crashed(_, _, restartAt: .some): true
    default: false
    }
  }

  /// A short description for menus and Settings.
  public var summary: String {
    switch self {
    case .unavailable: "Unavailable in this edition"
    case .stopped: "Not hosting"
    case .awaitingConfirmation: "Waiting for your confirmation\u{2026}"
    case .connecting(let url): "Connecting to \(url.host() ?? url.absoluteString)\u{2026}"
    case .connected(let url, _): "Hosting for \(url.host() ?? url.absoluteString)"
    case .stopping: "Stopping\u{2026}"
    case .crashed(_, let exit, let restartAt):
      restartAt == nil ? "Crashed: \(exit.summary)" : "Crashed; restarting soon"
    case .failed(let error): error.message
    }
  }
}
