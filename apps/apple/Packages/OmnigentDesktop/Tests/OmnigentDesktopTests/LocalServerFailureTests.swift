import Foundation
import Testing

@testable import OmnigentDesktop

/// What the user sees when a step of starting, stopping or installing fails underneath them.
@Suite("Local server failures")
@MainActor
struct LocalServerFailureTests {
  private let problem = LocalServerError.spawnSetupFailed("no permission")

  /// A process that exits cleanly having found the server already running, as the CLI does.
  private func exitsAfterHandingOff(_ write: @escaping @Sendable () -> Void) -> FakeRunner.Behavior
  {
    { process in
      write()
      process.exit(.exited(0))
    }
  }

  @Test("a clean exit with nothing to hand off to reads as an early exit")
  func cleanExitWithNoServer() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.script(exitsAfterHandingOff {})
    await harness.manager.startServer(trigger: .launch)
    guard case .failed(.exitedBeforeReady(.exited(0), _)) = harness.manager.server else {
      Issue.record("expected an early exit, got \(harness.manager.server)")
      return
    }
  }

  @Test("a clean exit because a server was already running uses that server")
  func cleanExitHandsOff() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.addExternal(LocalProcessIdentity(pid: 77, startMicroseconds: 1))
    harness.probe.answer(try loopback(7300), .ready(nil))
    let dataDirectory = harness.dataDirectory
    harness.runner.script(
      exitsAfterHandingOff {
        do {
          try FileManager.default.createDirectory(
            at: dataDirectory, withIntermediateDirectories: true)
          try "77\n7300\n".write(
            to: CanonicalServerRecord.fileURL(dataDirectory: dataDirectory), atomically: true,
            encoding: .utf8)
        } catch {
          Issue.record("could not write the pidfile: \(error)")
        }
      })
    await harness.manager.startServer(trigger: .launch)
    guard case .running(let endpoint, _) = harness.manager.server else {
      Issue.record("expected the running server, got \(harness.manager.server)")
      return
    }
    #expect(endpoint.port == 7300)
  }

  @Test("a configured port past the valid range fails instead of probing it")
  func portOutOfRange() async throws {
    let harness = try LocalServerHarness { $0.port = 70_000 }
    defer { harness.cleanUp() }
    await harness.manager.startServer(trigger: .launch)
    #expect(harness.manager.server == .failed(.spawnSetupFailed("port 70000 is out of range")))
    #expect(harness.runner.processes.first?.signals == [.interrupt], "it is stopped too")
  }

  @Test("a pidfile that can't be read while waiting is the timeout's reason")
  func unreadablePidfileWhileWaiting() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    let pidfile = CanonicalServerRecord.fileURL(dataDirectory: harness.dataDirectory)
    harness.runner.script({ _ in
      do {
        try FileManager.default.createDirectory(at: pidfile, withIntermediateDirectories: true)
      } catch {
        Issue.record("could not block the pidfile: \(error)")
      }
    })
    await harness.manager.startServer(trigger: .launch)
    guard case .failed(.readinessTimedOut(_, let lastProblem)) = harness.manager.server else {
      Issue.record("expected a timeout, got \(harness.manager.server)")
      return
    }
    #expect(lastProblem?.contains(pidfile.lastPathComponent) == true, "\(lastProblem ?? "")")
  }

  @Test("a port check that fails shows why, and nothing starts")
  func portCheckFails() async throws {
    let harness = try LocalServerHarness { $0.port = 7301 }
    defer { harness.cleanUp() }
    harness.runner.failPortChecks(with: problem)
    await harness.manager.startServer(trigger: .launch)
    #expect(harness.manager.server == .failed(problem))
    #expect(harness.runner.launches.isEmpty)
  }

  @Test("Stop Server with nothing running leaves stopped, or unavailable, as it was")
  func stopWithNothingRunning() async throws {
    let available = try LocalServerHarness()
    defer { available.cleanUp() }
    await available.manager.stopServer()
    #expect(available.manager.server == .stopped)
    let unavailable = try LocalServerHarness(capability: .unavailable(.appSandbox))
    defer { unavailable.cleanUp() }
    let before = unavailable.manager.server
    await unavailable.manager.stopServer()
    #expect(unavailable.manager.server == before)
  }

  @Test("a start the app abandons ends without failing")
  func cancelledStart() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    let start = Task { await harness.manager.startServer(trigger: .launch) }
    start.cancel()
    await start.value
    if case .failed(let error) = harness.manager.server {
      Issue.record("a cancelled start failed: \(error)")
    }
  }

  @Test("a rejected server that won't take the stop signal still fails, and logs why")
  func failedSignalOnRejectedServer() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.script(announces(7302))
    harness.probe.answer(try loopback(7302), .rejected("not omnigent"))
    harness.runner.failSignals(with: problem)
    await harness.manager.startServer(trigger: .launch)
    guard case .failed(.notAnOmnigentServer) = harness.manager.server else {
      Issue.record("expected a rejection, got \(harness.manager.server)")
      return
    }
    #expect(harness.manager.serverLog.text.contains("no permission"))
  }

  @Test("an unreadable pidfile is logged and no server is found")
  func unreadablePidfileOnAdoption() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    let pidfile = CanonicalServerRecord.fileURL(dataDirectory: harness.dataDirectory)
    try FileManager.default.createDirectory(at: pidfile, withIntermediateDirectories: true)
    #expect(await harness.manager.existingServer() == nil)
    #expect(harness.manager.serverLog.text.contains(pidfile.lastPathComponent))
  }

  @Test("a stray server or host that won't stop is logged, not ignored")
  func strayProcessesWontStop() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    let server = LocalProcessIdentity(pid: 58, startMicroseconds: 1)
    let host = LocalProcessIdentity(pid: 59, startMicroseconds: 1)
    harness.runner.addExternal(server)
    harness.runner.addExternal(host)
    try harness.records.write(
      LocalServerRecord(kind: .server, process: server, port: 7303, commandLine: "omnigent server"))
    try harness.records.write(
      LocalServerRecord(kind: .host, process: host, port: nil, commandLine: "omnigent host"))
    harness.runner.failSignals(with: problem)
    #expect(await harness.manager.existingServer() == nil)
    #expect(harness.manager.serverLog.text.contains("no permission"))
    await harness.manager.launch()
    #expect(harness.manager.hostLog.text.contains("no permission"))
  }

  @Test("an unreadable host record is logged at launch and hosting isn't touched")
  func unreadableHostRecord() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    var reported: [LocalServerError] = []
    harness.manager.reportIssue = { reported.append($0) }
    let record = harness.records.fileURL(.host)
    try FileManager.default.createDirectory(
      at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{".utf8).write(to: record)
    await harness.manager.launch()
    #expect(reported.count == 1)
    #expect(harness.runner.externalSignals.isEmpty)
  }

  @Test("a host that won't stop after timing out is logged")
  func hostWontStop() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.manager.confirmHostMode = { _ in true }
    harness.runner.failSignals(with: problem)
    await harness.manager.startHost(serverURL: try loopback(7000))
    #expect(harness.manager.hostLog.text.contains("no permission"))
    guard case .failed(.readinessTimedOut) = harness.manager.host else {
      Issue.record("expected a timeout, got \(harness.manager.host)")
      return
    }
  }
}

/// Installing, signing in and one-shot commands failing.
@Suite("Local command failures")
@MainActor
struct LocalCommandFailureTests {
  private let problem = LocalServerError.spawnSetupFailed("no permission")

  @Test("a server that survives even a kill fails its stop and says so")
  func survivesKill() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.ignoreTerminate()
    harness.runner.surviveKill()
    harness.runner.script(announces(7304))
    harness.probe.answer(try loopback(7304), .ready(nil))
    await harness.manager.startServer(trigger: .launch)
    await harness.manager.stopServer()
    guard case .failed(.commandFailed(_, _, let output)) = harness.manager.server else {
      Issue.record("expected a failed stop, got \(harness.manager.server)")
      return
    }
    #expect(output == "the process did not exit")
  }

  @Test("a recovered server whose PID moved on isn't signaled when stopped")
  func recoveredPidReused() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    let identity = LocalProcessIdentity(pid: 60, startMicroseconds: 1)
    harness.runner.addExternal(identity)
    try harness.records.write(
      LocalServerRecord(kind: .server, process: identity, port: 7305, commandLine: "omnigent"))
    harness.probe.answer(try loopback(7305), .ready(nil))
    await harness.manager.startServer(trigger: .launch)
    #expect(harness.manager.server.endpoint?.port == 7305)
    harness.runner.addExternal(LocalProcessIdentity(pid: 60, startMicroseconds: 2))
    await harness.manager.stopServer()
    #expect(harness.runner.externalSignals.isEmpty)
    #expect(harness.manager.server == .stopped)
  }

  @Test("a CLI stop that can't launch fails the stop with the reason")
  func adoptedStopWontLaunch() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.addExternal(LocalProcessIdentity(pid: 61, startMicroseconds: 1))
    try harness.writeCanonicalRecord(pid: 61, port: 7306)
    harness.probe.answer(try loopback(7306), .ready(nil))
    await harness.manager.startServer(trigger: .launch)
    #expect(harness.manager.server.endpoint?.port == 7306)
    harness.runner.failLaunches(with: problem)
    await harness.manager.stopServer()
    #expect(harness.manager.server == .failed(problem))
  }

  @Test("records that can't be written or removed are logged and the server still runs")
  func recordsUnwritable() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    var reported: [LocalServerError] = []
    harness.manager.reportIssue = { reported.append($0) }
    let directory = harness.records.fileURL(.server).deletingLastPathComponent()
    try Data().write(to: directory)
    harness.runner.script(announces(7307))
    harness.probe.answer(try loopback(7307), .ready(nil))
    await harness.manager.startServer(trigger: .launch)
    #expect(harness.manager.server.endpoint?.port == 7307)
    #expect(!reported.isEmpty)
    await harness.manager.stopServer()
    #expect(harness.manager.server == .stopped)
  }

  @Test("an installer that can't launch fails the install and logs why")
  func installerWontLaunch() async throws {
    let harness = try LocalServerHarness(executables: [LocalServerHarness.cliPath, "/fake/bin/uv"])
    defer { harness.cleanUp() }
    harness.runner.failLaunches(with: problem)
    await harness.manager.installCLI()
    #expect(harness.manager.cliInstall != .idle)
    #expect(harness.manager.serverLog.text.contains("no permission"))
  }

  @Test("no login shell PATH falls back to the system directories and says so")
  func installWithoutLoginShell() async throws {
    let harness = try LocalServerHarness(executables: [LocalServerHarness.cliPath, "/usr/bin/uv"])
    defer { harness.cleanUp() }
    var dependencies = harness.dependencies
    dependencies.cliSystem.loginShellPath = { () throws(LocalServerError) in
      throw .spawnSetupFailed("no shell")
    }
    let manager = LocalServerManager(
      capability: .available, preferences: harness.preferences, dependencies: dependencies)
    harness.runner.script({ process in process.exit(.exited(0)) })
    await manager.installCLI()
    #expect(manager.serverLog.text.contains("Could not read your login shell's PATH: "))
    let path = harness.runner.launches.first?.environment["PATH"] ?? ""
    #expect(path.contains("/usr/bin:/bin:/usr/sbin:/sbin"))
  }

  @Test("omnigent login that can't launch stops before hosting")
  func signInWontLaunch() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.manager.confirmHostMode = { _ in true }
    harness.probe.answerSignIn(.signInNeeded)
    harness.runner.failLaunches(with: problem)
    await harness.manager.startHost(serverURL: try url("https://omnigent.example.com"))
    guard case .failed(.hostAuthenticationRequired) = harness.manager.host else {
      Issue.record("expected an authentication failure, got \(harness.manager.host)")
      return
    }
    #expect(harness.manager.hostLog.text.contains("no permission"))
  }

  @Test("a command past its timeout whose kill fails says both")
  func commandKillFails() async throws {
    let runner = FakeRunner()
    runner.script({ process in
      runner.failSignals(with: .spawnSetupFailed("no permission"))
      Task {
        for _ in 0..<40 { await Task.yield() }
        process.exit(.signaled(9))
      }
    })
    let launch = LocalProcessLaunch(
      executable: URL(filePath: "/bin/sh"), arguments: [], environment: [:],
      workingDirectory: FileManager.default.temporaryDirectory)
    let thrown = await #expect(throws: LocalServerError.self) {
      _ = try await LocalCommand.run(
        launch, runner: runner, clock: FakeClock(), timeout: .seconds(5))
    }
    guard case .commandFailed(_, _, let output) = thrown else {
      Issue.record("expected a failed command, got \(String(describing: thrown))")
      return
    }
    #expect(output.contains("killing it failed: "), "\(output)")
  }

  @Test("the real clock's sleep ends on cancellation, which is how a restart is called off")
  func systemClock() async {
    let clock = SystemLocalServerClock()
    let before = clock.now
    let sleep = Task { try await clock.sleep(for: .seconds(60)) }
    sleep.cancel()
    await #expect(throws: CancellationError.self) { try await sleep.value }
    #expect(before.duration(to: clock.now) < .seconds(5))
  }

  @Test("a blank data directory variable is the same as none")
  func blankDataDirectory() throws {
    let harness = try LocalServerHarness { $0.dataDirectory = nil }
    defer { harness.cleanUp() }
    let home = harness.root
    let chosen = harness.preferences.effectiveDataDirectory(
      environment: ["OMNIGENT_DATA_DIR": "  "], home: home)
    let unset = harness.preferences.effectiveDataDirectory(environment: [:], home: home)
    #expect(chosen == unset)
    let set = harness.preferences.effectiveDataDirectory(
      environment: ["OMNIGENT_DATA_DIR": "/custom"], home: home)
    #expect(set.path == "/custom")
  }
}
