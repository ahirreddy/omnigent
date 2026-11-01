public import Foundation
public import Observation

/// The CLI lookup's state.
nonisolated public enum LocalCLIState: Equatable, Sendable {
  /// Not looked for yet.
  case notChecked
  /// Looking.
  case checking
  /// Found.
  case found(LocalCLIResolution)
  /// Not found, or the configured path is invalid.
  case missing(LocalServerError)

  /// The resolution when found.
  public var resolution: LocalCLIResolution? {
    if case .found(let resolution) = self { return resolution }
    return nil
  }
}

/// Runs Omnigent entirely on this Mac: starts, adopts, supervises and stops `omnigent server`
/// and, with the user's confirmation, `omnigent host`, as the Electron shell's `server_manager.js`
/// does.
///
/// - Server: `omnigent server --host 127.0.0.1 --no-open` in the foreground under the app, so its
///   output streams into `serverLog`. With an automatic port it is the CLI's canonical local
///   server (6767, or a free port when that is taken), registered in `<data dir>/local_server.pid`
///   so `omnigent run` in Terminal reuses it. A fixed port runs a dedicated server with
///   `--port`. Ready means `/health` answers `{"status":"ok"}` and the manifest is valid or 404.
/// - Host: `omnigent host --server <url> --non-interactive`, only after `confirmHostMode`
///   approves, because host mode runs agents with this user's permissions. Connected means the
///   CLI printed its `✓ Connected` line. Hosting is never started automatically.
/// - Ownership: a process this launch spawned is `.owned`. One an earlier launch spawned and left
///   behind (the app crashed; macOS has no parent-death signal) is found through the app's
///   record and is `.recovered`: a server is reused and a host is stopped, since consent to host
///   lasts one session. A server started in Terminal is `.adopted` and never stopped on quit.
/// - Crashes: an owned process that exits on its own restarts with `restartPolicy` backoff when
///   `preferences.restartOnCrash` is on.
/// - Errors: every failure becomes `server`, `host` or `cli` state and goes to `reportIssue`.
@Observable
public final class LocalServerManager {
  /// Timeouts and polling.
  public struct Timing: Sendable {
    /// How long a server may take to become ready. A first boot runs migrations; the CLI allows
    /// up to 120 seconds.
    public var serverReadiness: Duration = .seconds(120)
    /// How long a host may take to connect.
    public var hostConnect: Duration = .seconds(60)
    /// Between readiness probes.
    public var pollInterval: Duration = .milliseconds(250)
    /// After SIGINT before SIGKILL. The server's own graceful shutdown takes up to 5 seconds.
    public var stopGrace: Duration = .seconds(8)
    /// For `omnigent server stop` and `omnigent host stop`.
    public var command: Duration = .seconds(30)

    /// The defaults.
    public init() {}
  }

  /// Everything the manager touches outside itself.
  public struct Dependencies: Sendable {
    /// Spawns and signals processes.
    public var runner: any LocalProcessRunning
    /// Probes servers.
    public var probe: any LocalServerProbing
    /// Polling and backoff time.
    public var clock: any LocalServerClock
    /// The app's records of what it spawned.
    public var records: LocalServerRecordStore
    /// What CLI discovery reads.
    public var cliSystem: LocalCLIDiscovery.System
    /// The app's environment, the base of the children's.
    public var environment: [String: String]
    /// The user's home directory.
    public var homeDirectory: URL
    /// A development build's source checkout, whose `.venv` is the last CLI candidate.
    public var developmentCheckout: URL?
    /// Timeouts.
    public var timing: Timing
    /// Crash restarts.
    public var restartPolicy: LocalRestartPolicy
    /// A CLI to use instead of discovering one, such as `uv run` in a source checkout.
    public var fixedCLI: LocalCLIResolution?

    /// Creates dependencies.
    /// - Parameters:
    ///   - runner: Spawns processes.
    ///   - probe: Probes servers.
    ///   - clock: Time.
    ///   - records: Process records.
    ///   - cliSystem: CLI discovery inputs.
    ///   - environment: Base environment.
    ///   - homeDirectory: Home.
    ///   - developmentCheckout: Source checkout.
    ///   - timing: Timeouts.
    ///   - restartPolicy: Restarts.
    ///   - fixedCLI: A CLI to use instead of discovery.
    public init(
      runner: any LocalProcessRunning, probe: any LocalServerProbing,
      clock: any LocalServerClock, records: LocalServerRecordStore,
      cliSystem: LocalCLIDiscovery.System, environment: [String: String], homeDirectory: URL,
      developmentCheckout: URL? = nil, timing: Timing = Timing(),
      restartPolicy: LocalRestartPolicy = LocalRestartPolicy(), fixedCLI: LocalCLIResolution? = nil
    ) {
      self.runner = runner
      self.probe = probe
      self.clock = clock
      self.records = records
      self.cliSystem = cliSystem
      self.environment = environment
      self.homeDirectory = homeDirectory
      self.developmentCheckout = developmentCheckout
      self.timing = timing
      self.restartPolicy = restartPolicy
      self.fixedCLI = fixedCLI
    }

    /// The real system.
    /// - Parameters:
    ///   - records: Where records live; defaults to Application Support.
    ///   - developmentCheckout: Pass `LocalServerManager.sourceCheckout` from debug builds.
    /// - Returns: Live dependencies.
    public static func live(
      records: LocalServerRecordStore = .applicationSupport(
        bundleIdentifier: Bundle.main.bundleIdentifier),
      developmentCheckout: URL? = nil
    ) -> Self {
      let runner = PosixSpawnProcessRunner()
      let clock = SystemLocalServerClock()
      return Self(
        runner: runner, probe: URLSessionLocalServerProbe(), clock: clock, records: records,
        cliSystem: .live(runner: runner, clock: clock),
        environment: ProcessInfo.processInfo.environment,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        developmentCheckout: developmentCheckout)
    }
  }

  /// Whether this build may run local processes at all.
  public let capability: LocalServerCapability
  /// Settings > Local Server.
  public let preferences: LocalServerPreferences
  /// The server's recent output.
  public let serverLog = LocalProcessLog()
  /// The host's recent output.
  public let hostLog = LocalProcessLog()
  /// The local server.
  public internal(set) var server: LocalServerStatus
  /// This Mac's host connection.
  public internal(set) var host: LocalHostStatus
  /// The CLI lookup.
  public internal(set) var cli: LocalCLIState = .notChecked

  /// Asks the user to allow host mode for a server. Defaults to declining; the desktop binds it
  /// to `HostModeConfirmation.confirm`.
  @ObservationIgnored public var confirmHostMode: (URL) async -> Bool = { _ in false }
  /// Called when a server becomes ready or is adopted.
  @ObservationIgnored public var onServerReady:
    (LocalServerEndpoint, LocalServerStartTrigger) ->
      Void = { _, _ in }
  /// Receives every error, in addition to the state.
  @ObservationIgnored public var reportIssue: (LocalServerError) -> Void = { _ in }

  @ObservationIgnored let dependencies: Dependencies
  @ObservationIgnored var serverRun: ProcessRun?
  @ObservationIgnored var hostRun: ProcessRun?
  @ObservationIgnored var serverCrashes = 0
  @ObservationIgnored var hostCrashes = 0
  @ObservationIgnored var serverRestart: Task<Void, Never>?
  @ObservationIgnored var hostRestart: Task<Void, Never>?
  @ObservationIgnored private var cliCacheKey: CLICacheKey?

  /// Creates a manager. Nothing runs until `launch()` or a start call.
  /// - Parameters:
  ///   - capability: `.unavailable` for the App Store edition.
  ///   - preferences: Settings.
  ///   - dependencies: The system.
  public init(
    capability: LocalServerCapability, preferences: LocalServerPreferences,
    dependencies: Dependencies = .live()
  ) {
    self.capability = capability
    self.preferences = preferences
    self.dependencies = dependencies
    switch capability {
    case .available:
      server = .stopped
      host = .stopped
    case .unavailable(let reason):
      server = .unavailable(reason)
      host = .unavailable(reason)
    }
  }

  /// The CLI data directory children use.
  public var dataDirectory: URL {
    preferences.effectiveDataDirectory(
      environment: dependencies.environment, home: dependencies.homeDirectory)
  }

  /// The server's own log files, written by the CLI.
  public var serverLogDirectory: URL {
    dataDirectory.appending(path: "logs/server", directoryHint: .isDirectory)
  }

  /// The source checkout this package was built from, for debug builds, when it has a `.venv`.
  /// Release builds return `nil`.
  public static var sourceCheckout: URL? {
    #if DEBUG
      // apps/apple/Packages/OmnigentDesktop/Sources/OmnigentDesktop/LocalServer/<file>.
      var url = URL(filePath: #filePath)
      for _ in 0..<8 { url.deleteLastPathComponent() }
      let venv = url.appending(path: ".venv/bin/omnigent").path
      return FileManager.default.isExecutableFile(atPath: venv) ? url : nil
    #else
      return nil
    #endif
  }

  /// Whether quitting has anything to stop: an owned or recovered server or host.
  public var hasProcessesToStopOnQuit: Bool {
    serverRun?.ownership.stopsOnQuit == true || hostRun?.ownership.stopsOnQuit == true
  }

  /// At app launch: stops a host an earlier launch left behind, finds the CLI, reuses a running
  /// server, and starts one when `preferences.startOnLaunch` is on.
  public func launch() async {
    guard capability.isAvailable else { return }
    await stopLeftoverHost()
    server = .checking
    if let found = await existingServer() {
      adopt(found, trigger: .launch)
      return
    }
    server = .stopped
    guard preferences.startOnLaunch else {
      await resolveCLI()
      return
    }
    await startServer(trigger: .launch)
  }

  /// Looks for the CLI again, for Settings > Refresh and after the CLI path changes.
  public func refreshCLI() async {
    cliCacheKey = nil
    await resolveCLI()
  }

  /// Stops what the app started (owned and recovered processes) and leaves adopted ones running.
  /// Call when the app quits.
  public func stopOwnedProcesses() async {
    if hostRun?.ownership.stopsOnQuit == true { await stopHost() }
    if serverRun?.ownership.stopsOnQuit == true { await stopServer() }
  }

  /// Waits for scheduled restarts to run, for tests.
  func waitForScheduledRestarts() async {
    while let task = serverRestart ?? hostRestart {
      await task.value
      if serverRestart == task { serverRestart = nil }
      if hostRestart == task { hostRestart = nil }
    }
  }

  /// The cached CLI, or a fresh lookup when the configured path changed.
  /// - Returns: The resolution, or `nil` with `cli` set to `.missing`, which Settings shows.
  @discardableResult
  func resolveCLI() async -> LocalCLIResolution? {
    let key = CLICacheKey(configuredPath: preferences.cliPath)
    if let fixed = dependencies.fixedCLI {
      cli = .found(fixed)
      return fixed
    }
    if cliCacheKey == key, let resolution = cli.resolution { return resolution }
    cli = .checking
    let discovery = LocalCLIDiscovery(
      configuredPath: preferences.cliPath, developmentCheckout: dependencies.developmentCheckout,
      system: dependencies.cliSystem)
    do {
      let resolution = try await discovery.discover()
      cli = .found(resolution)
      cliCacheKey = key
      for warning in resolution.warnings { serverLog.appendEvent(warning) }
      return resolution
    } catch {
      cli = .missing(error)
      cliCacheKey = nil
      return nil
    }
  }

  /// Why the CLI is unavailable, after `resolveCLI()` returned `nil`.
  var cliError: LocalServerError {
    if case .missing(let error) = cli { return error }
    return .cliNotFound(searched: [])
  }

  /// Records an error as state and reports it.
  func failServer(_ error: LocalServerError) {
    server = .failed(error)
    serverLog.appendEvent(error.message)
    reportIssue(error)
  }

  /// Records a host error as state and reports it.
  func failHost(_ error: LocalServerError) {
    host = .failed(error)
    hostLog.appendEvent(error.message)
    reportIssue(error)
  }

  /// Logs and reports an error that does not change state, such as an unreadable stale record.
  func note(_ error: LocalServerError, in log: LocalProcessLog) {
    log.appendEvent(error.message)
    reportIssue(error)
  }
}

/// What a cached CLI lookup depended on.
struct CLICacheKey: Equatable {
  var configuredPath: String?
}

/// One supervised process: spawned by this launch (`handle` set) or found through a record.
final class ProcessRun {
  let kind: LocalServerRecord.Kind
  let ownership: LocalServiceOwnership
  let handle: (any LocalProcessHandle)?
  let pid: Int32
  let identity: LocalProcessIdentity?
  let commandLine: String
  let launchDate = Date()
  var port: Int?
  var serverURL: URL?
  var exit: LocalProcessExit?
  var outputFinished = false
  var stopRequested = false
  var readyAt: ContinuousClock.Instant?
  var connected = false
  var alreadyHosted = false
  var tasks: [Task<Void, Never>] = []

  init(
    kind: LocalServerRecord.Kind, ownership: LocalServiceOwnership,
    handle: (any LocalProcessHandle)?, pid: Int32, identity: LocalProcessIdentity?,
    commandLine: String
  ) {
    self.kind = kind
    self.ownership = ownership
    self.handle = handle
    self.pid = pid
    self.identity = identity
    self.commandLine = commandLine
  }

  func cancelTasks() {
    for task in tasks { task.cancel() }
    tasks = []
  }
}
