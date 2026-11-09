import Foundation
import Synchronization
import Testing

@testable import OmnigentDesktop

/// A child that exited while something it left behind holds its output pipes open.
private final class HeldPipeProcess: LocalProcessHandle {
  let pid: Int32 = 4_321
  let output: AsyncStream<LocalProcessOutput>
  private let continuation: AsyncStream<LocalProcessOutput>.Continuation

  init(printing line: String) {
    (output, continuation) = AsyncStream.makeStream(of: LocalProcessOutput.self)
    continuation.yield(LocalProcessOutput(.standardOutput, Data(line.utf8)))
  }

  func waitForExit() async -> LocalProcessExit {
    await Task.yield()  // A real wait suspends until the exit.
    return .exited(0)
  }

  func send(_ signal: LocalProcessSignal) throws(LocalServerError) {}
}

/// Spawns one process that keeps its pipes open after it exits.
private struct HeldPipeRunner: LocalProcessRunning {
  func launch(_ launch: LocalProcessLaunch) throws(LocalServerError) -> any LocalProcessHandle {
    HeldPipeProcess(printing: "done\n")
  }
  func identity(of pid: Int32) -> LocalProcessIdentity? { nil }
  func waitForExit(ofUnrelated pid: Int32) async { await Task.yield() }
  func send(_ signal: LocalProcessSignal, toGroupOf pid: Int32) throws(LocalServerError) {}
  func isLoopbackPortAvailable(_ port: Int) throws(LocalServerError) -> Bool { true }
}

/// Stopping things that are waiting, and the live pieces behind the manager.
@Suite("Local server cancellation")
@MainActor
struct LocalServerCancellationTests {
  private func crashedServer(_ harness: LocalServerHarness) async throws {
    harness.runner.script(announces(6767))
    harness.probe.answer(try loopback(6767), .ready(nil))
    await harness.manager.startServer()
    let process = try #require(harness.runner.processes.first)
    harness.clock.holdLaterSleeps()
    process.exit(.signaled(9))
    await waitUntil(within: .seconds(5)) {
      guard case .crashed = harness.manager.server else { return false }
      return harness.clock.recordedSleeps.contains(.seconds(1))
    }
  }

  @Test("Stop Server during the restart backoff means no restart happens")
  func stopDuringServerBackoff() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    try await crashedServer(harness)
    await harness.manager.stopServer()
    await harness.manager.waitForScheduledRestarts()
    #expect(harness.manager.server == .stopped)
    #expect(harness.runner.launches.count == 1)
  }

  @Test("Stop Host during the reconnect backoff means no reconnect happens")
  func stopDuringHostBackoff() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.manager.confirmHostMode = { _ in true }
    let server = try loopback(7000)
    harness.runner.script { $0.print("\u{2713} Connected as 'mac'.") }
    await harness.manager.startHost(serverURL: server)
    #expect(harness.manager.host == .connected(serverURL: server, .owned))
    let process = try #require(harness.runner.processes.first)
    harness.clock.holdLaterSleeps()
    process.exit(.exited(9))
    await waitUntil(within: .seconds(5)) {
      guard case .crashed = harness.manager.host else { return false }
      return !harness.clock.recordedSleeps.isEmpty
    }
    await harness.manager.stopHost()
    await harness.manager.waitForScheduledRestarts()
    #expect(harness.manager.host == .stopped)
    #expect(harness.runner.launches.count == 1)
  }

  @Test("a stop whose own task is cancelled still kills a server that ignores the signal")
  func cancelledStop() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.ignoreTerminate()
    harness.runner.script(announces(6767))
    harness.probe.answer(try loopback(6767), .ready(nil))
    await harness.manager.startServer()
    let stop = Task { await harness.manager.stopServer() }
    stop.cancel()
    await stop.value
    #expect(harness.runner.processes.first?.signals == [.interrupt, .kill])
    guard case .failed(.commandFailed) = harness.manager.server else {
      Issue.record("it stopped waiting, so it can't say stopped: \(harness.manager.server)")
      return
    }
  }

  @Test("a fixed CLI is used without any search")
  func fixedCLI() async throws {
    let harness = try LocalServerHarness(executables: [])
    defer { harness.cleanUp() }
    var dependencies = harness.dependencies
    let fixed = LocalCLIResolution(
      command: LocalCLICommand(executable: URL(filePath: "/opt/omnigent"), source: .configured),
      loginShellPath: nil)
    dependencies.fixedCLI = fixed
    let manager = LocalServerManager(
      capability: .available, preferences: harness.preferences, dependencies: dependencies)
    #expect(await manager.resolveCLI() == fixed)
    #expect(manager.cli == .found(fixed))
  }

  @Test("the live system reads the login shell's PATH through its runner")
  func liveLoginShell() async throws {
    let runner = FakeRunner()
    let marker = LoginShell.marker
    runner.script { process in
      process.print("\(marker)/opt/bin\(marker)")
      process.exit(.exited(0))
    }
    let system = LocalCLIDiscovery.System.live(runner: runner, clock: FakeClock())
    #expect(try await system.loginShellPath() == "/opt/bin")
    #expect(system.isExecutableFile("/bin/sh"))
    #expect(!system.isExecutableFile("/bin"))
  }

  @Test("output a leftover child holds open stops being read soon after the exit")
  func drainLimit() async throws {
    let clock = FakeClock()
    clock.holdLaterSleeps()
    let result = try await LocalCommand.run(
      LocalProcessLaunch(executable: URL(filePath: "/bin/sh"), arguments: [], environment: [:]),
      runner: HeldPipeRunner(), clock: clock, timeout: .seconds(600),
      drainLimit: .milliseconds(5))
    #expect(result.exit == .exited(0))
    #expect(result.standardOutput == "done\n")
  }

  @Test("the real clock sleeps and reports cancellation")
  func realClock() async throws {
    let clock = SystemLocalServerClock()
    let before = clock.now
    try await clock.sleep(for: .milliseconds(1))
    #expect(clock.now > before)
    let cancelled = Task {
      do {
        try await clock.sleep(for: .seconds(600))
        return false
      } catch {
        return error is CancellationError
      }
    }
    cancelled.cancel()
    #expect(await cancelled.value)
  }
}
