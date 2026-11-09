import Foundation
import Testing

@testable import OmnigentDesktop

/// Answers ready, but only after long enough for a process's exit to be noticed.
private struct SlowProbe: LocalServerProbing {
  func probe(_ baseURL: URL) async -> LocalServerProbeResult {
    do {
      try await Task.sleep(for: .milliseconds(30))
    } catch {
      return .notReady("cancelled")
    }
    return .ready(nil)
  }

  func signInProbe(_ serverURL: URL, bearer: String?) async -> CLISignInProbe {
    await Task.yield()  // A real probe suspends on the network.
    return .unreachable
  }
}

/// A CLI that finds a server already running exits cleanly, and that server is the one to use.
@Suite("Local server hand-off")
@MainActor
struct LocalServerHandOffTests {
  @Test("a clean exit that hands off to a server already there adopts it instead of owning it")
  func handsOffToRecordedServer() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.addExternal(LocalProcessIdentity(pid: 77, startMicroseconds: 1))
    try harness.writeCanonicalRecord(pid: 77, port: 7_300)
    // Old enough not to read as this launch's own record.
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
      ofItemAtPath: CanonicalServerRecord.fileURL(dataDirectory: harness.dataDirectory).path)
    // Still starting when first asked, so the app spawns the CLI, which finds it and exits.
    harness.probe.answer(try loopback(7_300), .notReady("starting"), .ready(nil))
    harness.runner.script { $0.exit(.exited(0)) }
    await harness.manager.startServer()
    #expect(harness.manager.server.endpoint?.port == 7_300)
    #expect(harness.manager.server.ownership == .adopted)
    #expect(!harness.manager.hasProcessesToStopOnQuit)
  }

  @Test("a CLI that exits while its port is being probed isn't credited with the server")
  func exitDuringProbe() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.addExternal(LocalProcessIdentity(pid: 77, startMicroseconds: 1))
    var dependencies = harness.dependencies
    dependencies.probe = SlowProbe()
    let manager = LocalServerManager(
      capability: .available, preferences: harness.preferences, dependencies: dependencies)
    let record = CanonicalServerRecord.fileURL(dataDirectory: harness.dataDirectory)
    let dataDirectory = harness.dataDirectory
    harness.runner.script { process in
      do {
        try FileManager.default.createDirectory(
          at: dataDirectory, withIntermediateDirectories: true)
        try "77\n7300\n".write(to: record, atomically: true, encoding: .utf8)
      } catch {
        Issue.record("could not write the pidfile: \(error)")
      }
      process.exit(.exited(0))
    }
    await manager.startServer()
    #expect(manager.server.endpoint?.port == 7_300)
    #expect(manager.server.ownership == .adopted)
    #expect(!manager.hasProcessesToStopOnQuit)
    #expect(harness.runner.launches.count == 1, "no restart on the way")
  }
}
