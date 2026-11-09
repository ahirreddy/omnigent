import Foundation
import OmnigentAuthUI
import OmnigentDesktop
import Synchronization
import Testing

@testable import OmnigentAppUI

/// A process runner that refuses to start anything and knows one process it did not start.
nonisolated private final class RefusingRunner: LocalProcessRunning {
  let launches = Mutex(0)
  let external: LocalProcessIdentity?

  init(external: LocalProcessIdentity? = nil) {
    self.external = external
  }

  func launch(_ launch: LocalProcessLaunch) throws(LocalServerError) -> any LocalProcessHandle {
    launches.withLock { $0 += 1 }
    throw .spawnFailed(executable: launch.executable.path, errno: 2)
  }

  func identity(of pid: Int32) -> LocalProcessIdentity? { external?.pid == pid ? external : nil }

  func waitForExit(ofUnrelated pid: Int32) async {
    // Runs until the manager stops watching: the process never exits.
    let (exits, continuation) = AsyncStream<Void>.makeStream()
    for await _ in exits {}
    continuation.finish()
  }

  func send(_ signal: LocalProcessSignal, toGroupOf pid: Int32) throws(LocalServerError) {}
  func isLoopbackPortAvailable(_ port: Int) throws(LocalServerError) -> Bool { true }
}

/// A server at one address that says it is ready.
nonisolated private struct ReadyProbe: LocalServerProbing {
  func probe(_ baseURL: URL) -> LocalServerProbeResult { .ready(nil) }
  func signInProbe(_ serverURL: URL, bearer: String?) -> CLISignInProbe { .unreachable }
}

/// "Get started locally": the setup screens over the local server manager.
@MainActor
@Suite("Local server setup", .serialized, .timeLimit(.minutes(1)))
struct LocalServerSetupTests {
  private struct Harness {
    let root: URL
    let manager: LocalServerManager
    let setup: LocalServerSetup
    let runner: RefusingRunner

    func cleanUp() {
      do {
        try FileManager.default.removeItem(at: root)
      } catch {
        Issue.record(error, "could not remove \(root.path)")
      }
    }
  }

  private static let cliPath = "/fake/bin/omnigent"

  private func harness(
    capability: LocalServerCapability = .available, cli: Set<String> = [Self.cliPath],
    running: (pid: Int32, port: Int)? = nil, logs: (@MainActor () -> Void)? = nil
  ) throws -> Harness {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let preferences = LocalServerPreferences(defaults: try scratchDefaults())
    preferences.dataDirectory = root.appending(path: "data").path
    if let running {
      let data = root.appending(path: "data")
      try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
      try "\(running.pid)\n\(running.port)\n".write(
        to: CanonicalServerRecord.fileURL(dataDirectory: data), atomically: true, encoding: .utf8)
    }
    let runner = RefusingRunner(
      external: running.map { LocalProcessIdentity(pid: $0.pid, startMicroseconds: 1) })
    let dependencies = LocalServerManager.Dependencies(
      runner: runner, probe: ReadyProbe(), clock: SystemLocalServerClock(),
      records: LocalServerRecordStore(directory: root.appending(path: "records")),
      cliSystem: LocalCLIDiscovery.System(
        homeDirectory: root, isExecutableFile: { cli.contains($0) },
        loginShellPath: { "/fake/bin:/usr/bin:/bin" }),
      environment: ["HOME": root.path], homeDirectory: root)
    let manager = LocalServerManager(
      capability: capability, preferences: preferences, dependencies: dependencies)
    let setup = try #require(LocalServerSetup(manager: manager, showLogs: logs))
    return Harness(root: root, manager: manager, setup: setup, runner: runner)
  }

  private func isFound(_ setup: LocalServerSetup) -> Bool {
    if case .found = setup.state.cli { true } else { false }
  }

  private func isMissing(_ setup: LocalServerSetup) -> Bool {
    if case .missing = setup.state.cli { true } else { false }
  }

  @Test("An edition that can't run processes offers no local setup")
  func unavailable() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let manager = LocalServerManager(
      capability: .unavailable(.appSandbox),
      preferences: LocalServerPreferences(defaults: try scratchDefaults()),
      dependencies: LocalServerManager.Dependencies(
        runner: RefusingRunner(), probe: ReadyProbe(), clock: SystemLocalServerClock(),
        records: LocalServerRecordStore(directory: root),
        cliSystem: LocalCLIDiscovery.System(
          homeDirectory: root, isExecutableFile: { _ in false }, loginShellPath: { "" }),
        environment: [:], homeDirectory: root))
    #expect(LocalServerSetup(manager: manager) == nil)
  }

  @Test("The landing learns whether the CLI is installed, and Recheck looks again")
  func findsTheCLI() async throws {
    let harness = try harness()
    defer { harness.cleanUp() }
    try await eventually("the CLI") { isFound(harness.setup) }

    let missing = try self.harness(cli: [])
    defer { missing.cleanUp() }
    try await eventually("the lookup") { isMissing(missing.setup) }
    missing.setup.actions(connect: { _ in }).recheckCLI()
    try await eventually("the recheck") { isMissing(missing.setup) }
  }

  @Test("Start connects to a server already running without starting another")
  func startReusesARunningServer() async throws {
    let harness = try harness(running: (pid: 4_242, port: 7_777))
    defer { harness.cleanUp() }
    final class Connected { var urls: [String] = [] }
    let connected = Connected()
    let actions = harness.setup.actions(connect: { connected.urls.append($0) })
    actions.start()
    try await eventually("the first connect") { !connected.urls.isEmpty }
    #expect(connected.urls.first?.contains("7777") == true)
    actions.start()
    try await eventually("the second connect") { connected.urls.count == 2 }
    #expect(harness.runner.launches.withLock { $0 } == 0)
    guard case .running(let url) = harness.setup.state.server else {
      Issue.record("the running server shows: \(harness.setup.state.server)")
      return
    }
    #expect(url.contains("7777"))
  }

  @Test("A server that can't start stays on the progress screen and connects nowhere")
  func startFails() async throws {
    let harness = try harness()
    defer { harness.cleanUp() }
    final class Connected { var urls: [String] = [] }
    let connected = Connected()
    harness.setup.actions(connect: { connected.urls.append($0) }).start()
    try await eventually("the failure") {
      if case .failed = harness.setup.state.server { true } else { false }
    }
    #expect(connected.urls.isEmpty)
  }

  @Test("Host for a server chosen before sign-in; signing in elsewhere keeps it waiting")
  func hostAfterSignIn() throws {
    let harness = try harness()
    defer { harness.cleanUp() }
    harness.setup.actions(connect: { _ in }).hostAfterSignIn("http://example.test:1/api")
    #expect(harness.setup.pendingHost == "http://example.test:1/api")
    harness.setup.didSignIn(to: "http://other.test:2")
    #expect(harness.setup.pendingHost != nil, "signed in somewhere else")
    harness.setup.didSignIn(to: "")
    #expect(harness.setup.pendingHost != nil, "no address to compare")
    harness.setup.didSignIn(to: "http://EXAMPLE.test:1")
    #expect(harness.setup.pendingHost == nil)
  }

  @Test("Show Logs and Install are passed through")
  func installAndLogs() async throws {
    final class Shown { var count = 0 }
    let shown = Shown()
    let harness = try harness(logs: { shown.count += 1 })
    defer { harness.cleanUp() }
    let actions = harness.setup.actions(connect: { _ in })
    actions.showLogs?()
    #expect(shown.count == 1)
    let installCLI = try #require(actions.installCLI)
    installCLI()
    try await eventually("the installer to try") {
      switch harness.setup.state.install {
      case .failed, .installing: true
      case .idle: harness.runner.launches.withLock { $0 } > 0
      }
    }
  }

  @Test("The installer's state reads on the install screen, and origins compare")
  func installStatesAndOrigins() {
    if case .idle = LocalServerSetup.install(.idle) {} else { Issue.record("idle") }
    if case .installing = LocalServerSetup.install(.installing) {} else { Issue.record("busy") }
    if case .failed("no") = LocalServerSetup.install(.failed("no")) {} else { Issue.record("no") }
    #expect(LocalServerSetup.sameServer("http://a:1/x", "http://A:1/y"))
    #expect(!LocalServerSetup.sameServer("http://a:1", "http://a:2"))
    #expect(!LocalServerSetup.sameServer("", "http://a:2"))
  }
}
