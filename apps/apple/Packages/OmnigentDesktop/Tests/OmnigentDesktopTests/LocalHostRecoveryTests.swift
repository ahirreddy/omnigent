import Foundation
import OmnigentViewTesting
import Testing

@testable import OmnigentDesktop

/// A host that crashes, times out, can't start or was found running.
@Suite("Local host recovery")
@MainActor
struct LocalHostRecoveryTests {
  private let connected: FakeRunner.Behavior = { $0.print("\u{2713} Connected as 'mac'.") }

  /// A manager hosting for a loopback tunnel that isn't its own server, already allowed.
  private func hosting(
    restartOnCrash: Bool = true, _ behaviors: [FakeRunner.Behavior] = []
  ) async throws -> (LocalServerHarness, URL) {
    let harness = try LocalServerHarness { $0.restartOnCrash = restartOnCrash }
    harness.manager.confirmHostMode = { _ in true }
    let url = try loopback(7000)
    harness.runner.script(connected)
    for behavior in behaviors { harness.runner.script(behavior) }
    await harness.manager.startHost(serverURL: url)
    #expect(harness.manager.host == .connected(serverURL: url, .owned))
    return (harness, url)
  }

  private func crash(_ harness: LocalServerHarness) async throws {
    let process = try #require(harness.runner.processes.last)
    process.exit(.exited(9))
    for _ in 0..<20 { await Task.yield() }
  }

  @Test("with restarts off, a crash stays down and Start Host is offered again")
  func crashStaysDown() async throws {
    let (harness, url) = try await hosting(restartOnCrash: false)
    defer { harness.cleanUp() }
    var reported: [LocalServerError] = []
    harness.manager.reportIssue = { reported.append($0) }
    try await crash(harness)
    #expect(harness.manager.host == .crashed(serverURL: url, .exited(9), restartAt: nil))
    #expect(harness.manager.host.canStart)
    #expect(reported.count == 1)
    #expect(harness.manager.host.tone == .bad)
  }

  @Test("a crash reconnects on its own without asking again")
  func crashReconnects() async throws {
    let (harness, url) = try await hosting()
    defer { harness.cleanUp() }
    var asked = 0
    harness.manager.confirmHostMode = { _ in
      asked += 1
      return true
    }
    harness.runner.script(connected)
    try await crash(harness)
    await waitUntil(within: .seconds(2)) { harness.runner.launches.count == 2 }
    await waitUntil(within: .seconds(2)) {
      harness.manager.host == .connected(serverURL: url, .owned)
    }
    #expect(harness.manager.host == .connected(serverURL: url, .owned))
    #expect(asked == 0)
    await harness.manager.stopOwnedProcesses()
  }

  @Test("repeated crashes stop at the limit and say so")
  func restartLimit() async throws {
    let (harness, _) = try await hosting()
    defer { harness.cleanUp() }
    let attempts = harness.dependencies.restartPolicy.maximumAttempts
    for _ in 0..<(attempts + 2) {
      // Each restart exits before connecting, which counts as another crash.
      harness.runner.script { $0.exit(.exited(1)) }
    }
    try await crash(harness)
    await waitUntil(within: .seconds(3)) {
      if case .failed = harness.manager.host { return true }
      return false
    }
    guard case .failed(.restartLimitReached) = harness.manager.host else {
      Issue.record("expected the restart limit, got \(harness.manager.host)")
      return
    }
  }

  @Test("Stop Host during a scheduled reconnect cancels it")
  func stopCancelsRestart() async throws {
    let (harness, _) = try await hosting()
    defer { harness.cleanUp() }
    try await crash(harness)
    await harness.manager.stopHost()
    #expect(harness.manager.host == .stopped)
    for _ in 0..<20 { await Task.yield() }
    #expect(harness.manager.host == .stopped)
  }

  @Test("a host that never reports connected times out and is stopped")
  func connectTimeout() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.manager.confirmHostMode = { _ in true }
    await harness.manager.startHost(serverURL: try loopback(7000))
    guard case .failed(.readinessTimedOut) = harness.manager.host else {
      Issue.record("expected a timeout, got \(harness.manager.host)")
      return
    }
    #expect(harness.runner.processes.first?.signals == [.interrupt])
  }

  @Test("a host that can't be spawned fails with the reason")
  func spawnFails() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.manager.confirmHostMode = { _ in true }
    harness.runner.failLaunches(with: .spawnSetupFailed("no pipes"))
    await harness.manager.startHost(serverURL: try loopback(7000))
    #expect(harness.manager.host == .failed(.spawnSetupFailed("no pipes")))
  }

  @Test("no command-line tool fails the host with what was searched")
  func noCLI() async throws {
    let harness = try LocalServerHarness(executables: [])
    defer { harness.cleanUp() }
    harness.manager.confirmHostMode = { _ in true }
    await harness.manager.startHost(serverURL: try loopback(7000))
    guard case .failed = harness.manager.host else {
      Issue.record("expected a failure, got \(harness.manager.host)")
      return
    }
    #expect(harness.runner.launches.isEmpty)
  }

  /// A manager that found a daemon already hosting for the server.
  private func adopted() async throws -> (LocalServerHarness, URL) {
    let harness = try LocalServerHarness()
    harness.manager.confirmHostMode = { _ in true }
    let url = try loopback(7000)
    harness.runner.script { process in
      process.print("Error: A host daemon is already running for this server (pid 77).")
      process.exit(.exited(1))
    }
    await harness.manager.startHost(serverURL: url)
    #expect(harness.manager.host == .connected(serverURL: url, .adopted))
    return (harness, url)
  }

  @Test("Stop Host on a daemon it found runs the CLI's own stop")
  func stopsAdopted() async throws {
    let (harness, url) = try await adopted()
    defer { harness.cleanUp() }
    harness.runner.script { $0.exit(.exited(0)) }
    await harness.manager.stopHost()
    #expect(harness.manager.host == .stopped)
    #expect(
      harness.runner.launches.last?.arguments == ["host", "stop", "--server", url.absoluteString])
  }

  @Test("a CLI stop that fails shows its output")
  func stopsAdoptedFails() async throws {
    let (harness, _) = try await adopted()
    defer { harness.cleanUp() }
    harness.runner.script { process in
      process.print("no such daemon")
      process.exit(.exited(2))
    }
    await harness.manager.stopHost()
    guard case .failed(.commandFailed(_, _, let output)) = harness.manager.host else {
      Issue.record("expected a command failure, got \(harness.manager.host)")
      return
    }
    #expect(output.contains("no such daemon"))
  }

  @Test("Stop Host with nothing running stays stopped")
  func stopWhileStopped() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    await harness.manager.stopHost()
    #expect(harness.manager.host == .stopped)
  }

  @Test("the CLI's config file follows its environment variable")
  func configFile() throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    #expect(harness.manager.cliConfigFile == harness.root.appending(path: ".omnigent/config.yaml"))
    #expect(try harness.manager.cliConfigText() == nil, "not generated yet")
    let directory = harness.root.appending(path: ".omnigent")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "host_id: mac\n".write(
      to: harness.manager.cliConfigFile, atomically: true, encoding: .utf8)
    #expect(try harness.manager.cliConfigText() == "host_id: mac\n")

    var absolute = harness.dependencies
    absolute.environment["OMNIGENT_CONFIG_HOME"] = " /custom/config "
    #expect(
      LocalServerManager(
        capability: .available, preferences: harness.preferences, dependencies: absolute
      ).cliConfigFile.path == "/custom/config/config.yaml")
    var tilde = harness.dependencies
    tilde.environment["OMNIGENT_CONFIG_HOME"] = "~/elsewhere"
    #expect(
      LocalServerManager(
        capability: .available, preferences: harness.preferences, dependencies: tilde
      ).cliConfigFile == harness.root.appending(path: "elsewhere/config.yaml"))
  }

  @Test("an edition that can't run the CLI has no config to read")
  func configUnavailable() throws {
    let harness = try LocalServerHarness(capability: .unavailable(.appSandbox))
    defer { harness.cleanUp() }
    #expect(try harness.manager.cliConfigText() == nil)
  }

  @Test("an unreadable config is an error, not an empty one")
  func configUnreadable() throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    try FileManager.default.createDirectory(
      at: harness.manager.cliConfigFile, withIntermediateDirectories: true)
    #expect(throws: (any Error).self) { try harness.manager.cliConfigText() }
  }
}
