import AppKit
import Foundation
import OmnigentViewTesting
import Testing

@testable import OmnigentDesktop

/// Finding, adopting and starting a server when things aren't as recorded.
@Suite("Local server edge cases")
@MainActor
struct LocalServerEdgeCaseTests {
  @Test("a recorded server that answers as something else isn't used")
  func canonicalRejected() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.addExternal(LocalProcessIdentity(pid: 55, startMicroseconds: 1))
    try harness.writeCanonicalRecord(pid: 55, port: 7100)
    harness.probe.answer(try loopback(7100), .rejected("not omnigent"))
    #expect(await harness.manager.existingServer() == nil)
    #expect(harness.manager.serverLog.text.contains("not omnigent"))
  }

  @Test("a recovered server that stopped answering is stopped")
  func unresponsiveRecovered() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    let identity = LocalProcessIdentity(pid: 56, startMicroseconds: 1)
    harness.runner.addExternal(identity)
    try harness.records.write(
      LocalServerRecord(
        kind: .server, process: identity, port: 7101, commandLine: "omnigent server"))
    #expect(await harness.manager.existingServer() == nil)
    #expect(harness.runner.externalSignals.map(\.0).contains(56))
    #expect(harness.manager.serverLog.text.contains("unresponsive"))
    #expect(try harness.records.read(.server) == nil)
  }

  @Test("an unreadable record is logged and reported, then ignored")
  func unreadableRecords() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    var reported: [LocalServerError] = []
    harness.manager.reportIssue = { reported.append($0) }
    try FileManager.default.createDirectory(
      at: harness.records.fileURL(.server).deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data("{".utf8).write(to: harness.records.fileURL(.server))
    #expect(await harness.manager.existingServer() == nil)
    #expect(reported.count == 1)
  }

  @Test("a host an earlier launch left running is stopped at launch")
  func strayHost() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    let identity = LocalProcessIdentity(pid: 57, startMicroseconds: 1)
    harness.runner.addExternal(identity)
    try harness.records.write(
      LocalServerRecord(kind: .host, process: identity, port: nil, commandLine: "omnigent host"))
    await harness.manager.launch()
    #expect(harness.runner.externalSignals.map(\.0).contains(57))
    #expect(harness.manager.hostLog.text.contains("earlier launch left running"))
  }

  @Test("a fixed port that's taken fails instead of starting")
  func busyFixedPort() async throws {
    let harness = try LocalServerHarness { $0.port = 7200 }
    defer { harness.cleanUp() }
    harness.runner.setBusy(7200)
    await harness.manager.startServer()
    #expect(harness.manager.server == .failed(.portUnavailable(port: 7200)))
    #expect(harness.runner.launches.isEmpty)
  }

  @Test("a server that can't be spawned fails with the reason")
  func spawnFails() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.failLaunches(with: .spawnSetupFailed("no pipes"))
    await harness.manager.startServer()
    #expect(harness.manager.server == .failed(.spawnSetupFailed("no pipes")))
  }

  @Test("stopping the local server disconnects the host that serves it first")
  func stopServerStopsHost() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    let url = try loopback(6767)
    harness.runner.script(announces(6767), { $0.print("\u{2713} Connected as 'mac'.") })
    harness.probe.answer(url, .ready(nil))
    await harness.manager.startServer()
    await harness.manager.startHost()
    #expect(harness.manager.host == .connected(serverURL: url, .owned))
    await harness.manager.stopServer()
    #expect(harness.manager.host == .stopped)
    #expect(harness.manager.server == .stopped)
  }

  @Test("the live system answers for real files, and the checkout lookup finds or skips a venv")
  func liveDependencies() throws {
    let system = LocalServerManager.Dependencies.live().cliSystem
    #expect(system.isExecutableFile("/bin/ls"))
    #expect(!system.isExecutableFile("/bin"))
    #expect(!system.isExecutableFile("/no/such/file"))
    if let checkout = LocalServerManager.sourceCheckout {
      #expect(
        FileManager.default.isExecutableFile(
          atPath: checkout.appending(path: ".venv/bin/omnigent").path))
    }
  }

  @Test("the login shell's PATH is read through the runner, and no PATH is an error")
  func loginShell() async throws {
    let runner = FakeRunner()
    let clock = FakeClock()
    let marker = LoginShell.marker
    runner.script { process in
      process.print("noise from a profile")
      process.print("\(marker)/opt/bin:/usr/bin\(marker)")
      process.exit(.exited(0))
    }
    #expect(try await LoginShell.path(runner: runner, clock: clock) == "/opt/bin:/usr/bin")
    #expect(runner.launches.first?.arguments.first == "-l")
    #expect(runner.launches.first?.environment["TERM"] == "dumb")
    runner.script { process in
      process.print("nothing useful")
      process.exit(.exited(0))
    }
    await #expect(throws: LocalServerError.self) {
      try await LoginShell.path(runner: runner, clock: clock)
    }
  }

  @Test("a command that runs too long is killed and says so")
  func commandTimeout() async throws {
    let runner = FakeRunner()
    let launch = LocalProcessLaunch(
      executable: URL(filePath: "/bin/sleep"), arguments: ["100"], environment: [:],
      workingDirectory: URL(filePath: "/"))
    do {
      _ = try await LocalCommand.run(
        launch, runner: runner, clock: FakeClock(), timeout: .seconds(1))
      Issue.record("expected a timeout")
    } catch {
      #expect(error.message.contains("timed out after 1 seconds and was killed"))
    }
    #expect(runner.processes.first?.signals == [.kill])
  }

  @Test("records that can't be read, written or removed say which file")
  func recordFailures() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "records-\(UUID())")
    defer {
      do {
        try FileManager.default.removeItem(at: root)
      } catch {
        Issue.record("cleanup failed: \(error)")
      }
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = LocalServerRecordStore(directory: root)
    try FileManager.default.createDirectory(
      at: store.fileURL(.server), withIntermediateDirectories: true)
    #expect(throws: LocalServerError.self) { try store.read(.server) }
    #expect(throws: LocalServerError.self) {
      try store.write(
        LocalServerRecord(
          kind: .server, process: LocalProcessIdentity(pid: 1, startMicroseconds: 1), port: nil,
          commandLine: "x"))
    }
    let file = root.appending(path: "file")
    try Data().write(to: file)
    let blocked = LocalServerRecordStore(directory: file)
    #expect(throws: LocalServerError.self) { try blocked.read(.host) }
    #expect(
      LocalServerRecordStore.applicationSupport(bundleIdentifier: "x.y").fileURL(.server).path
        .contains("x.y/LocalServer"))
    #expect(
      LocalServerRecordStore.applicationSupport(bundleIdentifier: nil).fileURL(.server).path
        .contains("ai.omnigent.desktop"))
  }

  @Test("a free port is available, a listening one isn't, and a gone process is no failure")
  func realSocketsAndSignals() async throws {
    let runner = PosixSpawnProcessRunner()
    let stub = try await LoopbackStub([:])
    defer { stub.stop() }
    #expect(try !runner.isLoopbackPortAvailable(stub.port))
    let nothing = Int32.max - 1
    try runner.send(.interrupt, toGroupOf: nothing)
    #expect(runner.identity(of: nothing) == nil)
  }

  @Test("the consent alert for a link names its server and defaults to Cancel")
  func linkConsent() throws {
    DesktopSideEffects.reset()
    let origin = try ServerOrigin(url: try url("https://new.test"))
    #expect(!DeepLinkConsentAlert.confirm(origin))
    #expect(SystemSideEffects.record.alertMessages == ["Open this Omnigent link?"])
    #expect(SystemSideEffects.record.activationCount == 1)
    SystemSideEffects.answer(alert: .alertSecondButtonReturn)
    #expect(DeepLinkConsentAlert.confirm(origin))
  }
}
