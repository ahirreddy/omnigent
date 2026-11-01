import Foundation
import Testing

@testable import OmnigentDesktop

/// Runs the real CLI from this checkout: `uv run --project <repo> --no-sync omnigent server`,
/// in an isolated data and config directory under `/private/tmp/claude-502/lsm-test`.
///
/// Opt in with `OMNIGENT_LOCAL_SERVER_INTEGRATION=1 swift test --filter LocalServerIntegration`.
/// It needs the repository's `.venv` (`uv sync`) and `uv` on `PATH` or in `~/.local/bin`.
@Suite(
  "Local server integration",
  .enabled(if: ProcessInfo.processInfo.environment["OMNIGENT_LOCAL_SERVER_INTEGRATION"] == "1"),
  .serialized)
@MainActor
struct LocalServerIntegrationTests {
  static let root = URL(filePath: "/private/tmp/claude-502/lsm-test", directoryHint: .isDirectory)

  /// Tests/OmnigentDesktopTests/<file> -> the repository root.
  static var repository: URL {
    var url = URL(filePath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return url
  }

  static func uv() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let directories =
      (environment["PATH"] ?? "").split(separator: ":").map(String.init)
      + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    for directory in directories {
      let candidate = URL(filePath: directory, directoryHint: .isDirectory)
        .appending(path: "uv").path
      if FileManager.default.isExecutableFile(atPath: candidate) { return URL(filePath: candidate) }
    }
    throw FixtureError(description: "uv not found on PATH or in ~/.local/bin")
  }

  func makeManager(records: String) throws -> LocalServerManager {
    let suite = "ai.omnigent.desktop.lsm.integration.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
      throw FixtureError(description: "no defaults suite")
    }
    let preferences = LocalServerPreferences(defaults: defaults)
    preferences.dataDirectory = Self.root.appending(path: "data").path
    let uvExecutable = try Self.uv()
    let environment = ProcessInfo.processInfo.environment
    var base = ["HOME": environment["HOME"] ?? NSHomeDirectory()]
    base["PATH"] = environment["PATH"]
    base["OMNIGENT_CONFIG_HOME"] = Self.root.appending(path: "config").path
    base["OMNIGENT_SKIP_WEB_UI"] = "true"
    let runner = PosixSpawnProcessRunner()
    let clock = SystemLocalServerClock()
    let cli = LocalCLIResolution(
      command: LocalCLICommand(
        executable: uvExecutable,
        prefixArguments: ["run", "--project", Self.repository.path, "--no-sync", "omnigent"],
        source: .explicit),
      loginShellPath: environment["PATH"])
    let dependencies = LocalServerManager.Dependencies(
      runner: runner, probe: URLSessionLocalServerProbe(), clock: clock,
      records: LocalServerRecordStore(directory: Self.root.appending(path: records)),
      cliSystem: .live(runner: runner, clock: clock), environment: base,
      homeDirectory: Self.root, fixedCLI: cli)
    return LocalServerManager(
      capability: .available, preferences: preferences, dependencies: dependencies)
  }

  @Test("starts uv run omnigent server, a second app adopts it, and stop ends it")
  func startAdoptStop() async throws {
    if FileManager.default.fileExists(atPath: Self.root.path) {
      try FileManager.default.removeItem(at: Self.root)
    }
    try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
    let manager = try makeManager(records: "records-a")
    await manager.startServer()
    guard case .running(let endpoint, .owned) = manager.server else {
      Issue.record("not running: \(manager.server)\n\(manager.serverLog.text)")
      return
    }
    let pid = try #require(endpoint.pid)
    #expect(
      manager.serverLog.text.contains("Starting omnigent server on 127.0.0.1:\(endpoint.port)"))
    #expect((endpoint.manifest?.manifestVersion ?? 0) >= 1)
    let canonical = try #require(
      try CanonicalServerRecord.read(dataDirectory: Self.root.appending(path: "data")))
    #expect(canonical.port == endpoint.port)

    // A second app instance (its own records) finds it through the CLI's pidfile.
    let other = try makeManager(records: "records-b")
    await other.startServer()
    #expect(other.server == .running(endpoint.withPID(canonical.pid), .adopted))
    await other.stopOwnedProcesses()
    #expect(PosixSpawnProcessRunner().identity(of: pid) != nil)

    await manager.stopServer()
    #expect(manager.server == .stopped)
    #expect(PosixSpawnProcessRunner().identity(of: pid) == nil)
    #expect(PosixSpawnProcessRunner().identity(of: canonical.pid) == nil)
    #expect(try CanonicalServerRecord.read(dataDirectory: Self.root.appending(path: "data")) == nil)
    #expect(try manager.dependencies.records.read(.server) == nil)
    await waitUntil(within: .seconds(5)) { other.server == .stopped }
    #expect(other.server == .stopped)
  }
}

extension LocalServerEndpoint {
  fileprivate func withPID(_ pid: Int32) -> Self {
    var copy = self
    copy.pid = pid
    return copy
  }
}
