public import Foundation
public import Observation

/// Settings > Local Server, persisted in `UserDefaults`.
@Observable
public final class LocalServerPreferences {
  enum Key {
    static let cliPath = "desktop.localServer.cliPath"
    static let startOnLaunch = "desktop.localServer.startOnLaunch"
    static let port = "desktop.localServer.port"
    static let dataDirectory = "desktop.localServer.dataDirectory"
    static let restartOnCrash = "desktop.localServer.restartOnCrash"
    static let showsMenuBarExtra = "desktop.menuBarExtra.shown"
  }

  @ObservationIgnored private let defaults: UserDefaults

  /// The CLI chosen in Settings, or `nil` to find it automatically.
  public var cliPath: String? {
    didSet { defaults.set(cliPath, forKey: Key.cliPath) }
  }
  /// Start (or adopt) the local server when the app opens. Off by default.
  public var startOnLaunch: Bool {
    didSet { defaults.set(startOnLaunch, forKey: Key.startOnLaunch) }
  }
  /// A fixed port, or `nil` for automatic: the CLI's canonical server, which prefers 6767,
  /// falls back to a free port and is shared with `omnigent run` in Terminal.
  public var port: Int? {
    didSet { defaults.set(port, forKey: Key.port) }
  }
  /// The CLI data directory (`OMNIGENT_DATA_DIR`), or `nil` for `~/.omnigent`.
  public var dataDirectory: String? {
    didSet { defaults.set(dataDirectory, forKey: Key.dataDirectory) }
  }
  /// Restart a server or host the app started when it crashes. On by default.
  public var restartOnCrash: Bool {
    didSet { defaults.set(restartOnCrash, forKey: Key.restartOnCrash) }
  }
  /// Show the Omnigent menu bar extra. On by default.
  public var showsMenuBarExtra: Bool {
    didSet { defaults.set(showsMenuBarExtra, forKey: Key.showsMenuBarExtra) }
  }

  /// Loads settings.
  /// - Parameter defaults: The store; tests pass a private suite.
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    cliPath = defaults.string(forKey: Key.cliPath).flatMap { $0.isEmpty ? nil : $0 }
    startOnLaunch = defaults.object(forKey: Key.startOnLaunch) as? Bool ?? false
    port = (defaults.object(forKey: Key.port) as? Int).flatMap {
      (1...65_535).contains($0) ? $0 : nil
    }
    dataDirectory = defaults.string(forKey: Key.dataDirectory).flatMap { $0.isEmpty ? nil : $0 }
    restartOnCrash = defaults.object(forKey: Key.restartOnCrash) as? Bool ?? true
    showsMenuBarExtra = defaults.object(forKey: Key.showsMenuBarExtra) as? Bool ?? true
  }

  /// The data directory in effect: the setting, else `OMNIGENT_DATA_DIR`, else `~/.omnigent`.
  /// - Parameters:
  ///   - environment: The app's environment.
  ///   - home: The home directory.
  /// - Returns: The directory.
  public func effectiveDataDirectory(environment: [String: String], home: URL) -> URL {
    let configured =
      dataDirectory
      ?? environment["OMNIGENT_DATA_DIR"].flatMap {
        $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
      }
    guard let configured else {
      return home.appending(path: ".omnigent", directoryHint: .isDirectory)
    }
    let expanded =
      configured.hasPrefix("~") ? home.path + String(configured.dropFirst()) : configured
    return URL(filePath: expanded, directoryHint: .isDirectory).standardizedFileURL
  }
}

/// When to restart a crashed process: exponential backoff that gives up after a run of crashes.
nonisolated public struct LocalRestartPolicy: Equatable, Sendable {
  /// Delays before restart attempts 1, 2, ...; the last repeats.
  public var delays: [Duration]
  /// Consecutive crashes after which restarting stops.
  public var maximumAttempts: Int
  /// Uptime after which a crash starts a fresh run of attempts.
  public var stableUptime: Duration

  /// Creates a policy.
  /// - Parameters:
  ///   - delays: Backoff delays.
  ///   - maximumAttempts: Attempts before giving up.
  ///   - stableUptime: Uptime that resets the count.
  public init(
    delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)],
    maximumAttempts: Int = 5, stableUptime: Duration = .seconds(60)
  ) {
    self.delays = delays.isEmpty ? [.seconds(1)] : delays
    self.maximumAttempts = maximumAttempts
    self.stableUptime = stableUptime
  }

  /// The delay before restart `attempt`, or `nil` once attempts are exhausted.
  /// - Parameter attempt: 1 for the first restart after a crash.
  /// - Returns: The delay.
  public func delay(forAttempt attempt: Int) -> Duration? {
    guard attempt >= 1, attempt <= maximumAttempts else { return nil }
    return delays[min(attempt, delays.count) - 1]
  }

  /// The attempt number for a new crash.
  /// - Parameters:
  ///   - previousAttempts: Consecutive crashes so far.
  ///   - uptime: How long the process ran, or `nil` when it never became ready.
  /// - Returns: The new consecutive count.
  public func attempt(after previousAttempts: Int, uptime: Duration?) -> Int {
    guard let uptime, uptime >= stableUptime else { return previousAttempts + 1 }
    return 1
  }
}
