import Foundation
import Testing

@testable import OmnigentDesktop

@Suite("Local server adoption and stopping")
@MainActor
struct LocalServerAdoptionTests {
  private let manifest = LocalServerManifest(manifestVersion: 1, serverVersion: "0.9.0")

  @Test("adopts the CLI's canonical server and never stops it on quit")
  func adoptsCanonical() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    let identity = LocalProcessIdentity(pid: 4_242, startMicroseconds: 1)
    harness.runner.addExternal(identity)
    try harness.writeCanonicalRecord(pid: 4_242, port: 7_777)
    harness.probe.answer(try loopback(7_777), .ready(manifest))

    await harness.manager.startServer()
    #expect(harness.manager.server.endpoint?.port == 7_777)
    #expect(harness.manager.server.ownership == .adopted)
    #expect(harness.runner.launches.isEmpty)
    #expect(!harness.manager.hasProcessesToStopOnQuit)

    await harness.manager.stopOwnedProcesses()
    #expect(harness.runner.externalSignals.isEmpty)
    #expect(harness.manager.server.ownership == .adopted)

    // An explicit Stop Server asks the CLI to stop it.
    harness.runner.script({ process in
      process.print("Stopped background server")
      process.exit(.exited(0))
    })
    await harness.manager.stopServer()
    #expect(harness.runner.launches.first?.arguments == ["server", "stop"])
    #expect(harness.runner.externalSignals.isEmpty)
    #expect(harness.manager.server == .stopped)
  }

  @Test("an adopted server that exits returns to stopped without a restart")
  func adoptedExit() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.addExternal(LocalProcessIdentity(pid: 4_243, startMicroseconds: 1))
    try harness.writeCanonicalRecord(pid: 4_243, port: 7_778)
    harness.probe.answer(try loopback(7_778), .ready(nil))
    await harness.manager.launch()
    #expect(harness.manager.server.ownership == .adopted)
    harness.runner.endExternal(4_243)
    await waitUntil(within: .seconds(5)) { harness.manager.server == .stopped }
    #expect(harness.manager.server == .stopped)
    #expect(harness.runner.launches.isEmpty)
  }

  @Test("quit stops only what the app started")
  func stopsOnlyOwned() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.script(announces(6767))
    harness.probe.answer(try loopback(6767), .ready(manifest))
    await harness.manager.startServer()
    #expect(harness.manager.hasProcessesToStopOnQuit)

    await harness.manager.stopOwnedProcesses()
    #expect(harness.runner.processes.first?.signals == [.interrupt])
    #expect(harness.manager.server == .stopped)
    #expect(try harness.records.read(.server) == nil)
  }

  @Test("a server that ignores SIGTERM is killed after the grace period")
  func escalatesToKill() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.ignoreTerminate()
    harness.runner.script(announces(6767))
    harness.probe.answer(try loopback(6767), .ready(manifest))
    await harness.manager.startServer()
    await harness.manager.stopServer()
    #expect(harness.runner.processes.first?.signals == [.interrupt, .kill])
    #expect(harness.manager.server == .stopped)
    #expect(harness.manager.serverLog.text.contains("killing it"))
  }

  @Test("a relaunch recovers the server an earlier launch started, and stops it on quit")
  func recoversOwnRecord() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    let identity = LocalProcessIdentity(pid: 5_151, startMicroseconds: 99)
    harness.runner.addExternal(identity)
    try harness.records.write(
      LocalServerRecord(kind: .server, process: identity, port: 8_888, commandLine: "omnigent"))
    harness.probe.answer(try loopback(8_888), .ready(manifest))

    await harness.manager.launch()
    #expect(harness.manager.server.ownership == .recovered)
    #expect(harness.manager.hasProcessesToStopOnQuit)
    await harness.manager.stopOwnedProcesses()
    #expect(harness.runner.externalSignals.map(\.0) == [5_151])
    #expect(harness.runner.externalSignals.map(\.1) == [.interrupt])
    #expect(harness.manager.server == .stopped)
  }

  @Test("a record whose PID was reused is removed and never signaled")
  func staleRecord() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.addExternal(LocalProcessIdentity(pid: 6_161, startMicroseconds: 2))
    try harness.records.write(
      LocalServerRecord(
        kind: .server, process: LocalProcessIdentity(pid: 6_161, startMicroseconds: 1),
        port: 8_889, commandLine: "omnigent"))
    harness.probe.answer(try loopback(8_889), .ready(manifest))

    await harness.manager.launch()
    #expect(harness.manager.server == .stopped)
    #expect(harness.runner.externalSignals.isEmpty)
    #expect(try harness.records.read(.server) == nil)
  }
}
