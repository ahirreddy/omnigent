import Foundation
import Testing

@testable import OmnigentDesktop

@Suite("Local server manager")
@MainActor
struct LocalServerManagerTests {
  private let manifest = LocalServerManifest(manifestVersion: 1, serverVersion: "0.9.0")

  @Test("one-click agent installs join the features the environment already set")
  func serverFeatures() {
    #expect(LocalServerManager.serverFeatures(nil) == "harness_install")
    #expect(LocalServerManager.serverFeatures("") == "harness_install")
    #expect(LocalServerManager.serverFeatures("canvas") == "canvas,harness_install")
    #expect(
      LocalServerManager.serverFeatures("-harness_install") == "-harness_install,harness_install")
  }

  @Test("starts the canonical server, waits for /health and the manifest, and records it")
  func readiness() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    let url = try loopback(6767)
    harness.runner.script(announces(6767))
    harness.probe.answer(url, .notReady("refused"), .notReady("HTTP 503"), .ready(manifest))
    var offered: [(LocalServerEndpoint, LocalServerStartTrigger)] = []
    harness.manager.onServerReady = { offered.append(($0, $1)) }

    await harness.manager.startServer()

    let endpoint = try #require(harness.manager.server.endpoint)
    #expect(endpoint.url == url)
    #expect(endpoint.manifest == manifest)
    #expect(harness.manager.server.ownership == .owned)
    #expect(harness.probe.count(url) == 3)
    #expect(offered.count == 1 && offered.first?.1 == .user)

    let launch = try #require(harness.runner.launches.first)
    #expect(launch.executable.path == LocalServerHarness.cliPath)
    #expect(launch.arguments == ["server", "--host", "127.0.0.1", "--no-open"])
    #expect(launch.environment["OMNIGENT_DATA_DIR"] == harness.dataDirectory.path)
    #expect(launch.environment["PYTHONUNBUFFERED"] == "1")
    #expect(launch.environment["OMNIGENT_FEATURES"] == "harness_install")
    #expect(launch.environment["OMNIGENT_LOG_TO_STDERR"] == "1")
    #expect(launch.environment["DYLD_INSERT_LIBRARIES"] == nil)
    #expect(launch.environment["PATH"]?.hasPrefix("/fake/bin:/usr/bin:/bin") == true)

    let record = try #require(try harness.records.read(.server))
    #expect(record.port == 6767)
    #expect(record.process.pid == harness.runner.processes.first?.pid)
    #expect(harness.manager.serverLog.text.contains("Starting omnigent server on 127.0.0.1:6767"))
  }

  @Test("a start from a window's setup reports its own trigger, so no other window is offered")
  func windowTrigger() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.script(announces(6767))
    harness.probe.answer(try loopback(6767), .ready(manifest))
    var triggers: [LocalServerStartTrigger] = []
    harness.manager.onServerReady = { triggers.append($1) }

    await harness.manager.startServer(trigger: .window)

    #expect(harness.manager.server.endpoint?.port == 6767)
    #expect(triggers == [.window])
  }

  @Test("a fixed port passes --port and is checked before spawning")
  func fixedPort() async throws {
    let harness = try LocalServerHarness { $0.port = 7100 }
    defer { harness.cleanUp() }
    harness.runner.setBusy(7100)
    await harness.manager.startServer()
    #expect(harness.manager.server == .failed(.portUnavailable(port: 7100)))
    #expect(harness.runner.launches.isEmpty)

    let free = try LocalServerHarness { $0.port = 7101 }
    defer { free.cleanUp() }
    free.probe.answer(try loopback(7101), .ready(nil))
    free.runner.script({ _ in })
    await free.manager.startServer()
    #expect(free.manager.server.endpoint?.port == 7101)
    #expect(free.manager.server.endpoint?.manifest == nil)
    #expect(free.runner.launches.first?.arguments.suffix(2) == ["--port", "7101"])
  }

  @Test("an exit before ready fails with the last output lines and clears the record")
  func exitBeforeReady() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.script({ process in
      process.print("Traceback: boom", stream: .standardError)
      process.exit(.exited(1))
    })
    await harness.manager.startServer()
    guard case .failed(.exitedBeforeReady(let exit, let lines)) = harness.manager.server else {
      Issue.record("expected exitedBeforeReady, got \(harness.manager.server)")
      return
    }
    #expect(exit == .exited(1))
    #expect(lines.contains("Traceback: boom"))
    #expect(try harness.records.read(.server) == nil)
  }

  @Test("readiness times out, then the process is terminated")
  func readinessTimeout() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.script(announces(6767))
    await harness.manager.startServer()
    guard case .failed(.readinessTimedOut(let seconds, let problem)) = harness.manager.server
    else {
      Issue.record("expected a timeout, got \(harness.manager.server)")
      return
    }
    #expect(seconds == 30)
    #expect(problem == "connection refused")
    #expect(harness.runner.processes.first?.signals == [.interrupt])
  }

  @Test("something else on the port is rejected, not adopted")
  func rejectsForeignServer() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    let url = try loopback(6767)
    harness.runner.script(announces(6767))
    harness.probe.answer(url, .rejected("/health returned HTTP 404"))
    await harness.manager.startServer()
    #expect(
      harness.manager.server
        == .failed(.notAnOmnigentServer(url: url, detail: "/health returned HTTP 404")))
  }

  @Test("a crash after ready restarts with backoff")
  func crashRestarts() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.script(announces(6767), announces(6767))
    harness.probe.answer(try loopback(6767), .ready(manifest))
    var triggers: [LocalServerStartTrigger] = []
    harness.manager.onServerReady = { triggers.append($1) }
    await harness.manager.startServer()
    let first = try #require(harness.runner.processes.first)

    first.exit(.signaled(9))
    // The fake clock makes the backoff instant, so wait for the second server to be ready.
    await waitUntil(within: .seconds(5)) {
      harness.runner.launches.count == 2 && harness.manager.server.endpoint != nil
    }
    await harness.manager.waitForScheduledRestarts()
    #expect(harness.manager.serverLog.text.contains("The process was ended by signal 9"))
    #expect(harness.manager.serverLog.text.contains("Restarting in 1 s (attempt 1 of 5)"))

    #expect(harness.runner.launches.count == 2)
    #expect(harness.manager.server.ownership == .owned)
    #expect(triggers == [.user, .restart(attempt: 1)])
    #expect(harness.clock.recordedSleeps.contains(.seconds(1)))
  }

  @Test("repeated startup failures back off and then give up")
  func restartLimit() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    let crashing: FakeRunner.Behavior = { $0.exit(.exited(3)) }
    harness.runner.script(announces(6767), crashing, crashing, crashing, crashing, crashing)
    harness.probe.answer(try loopback(6767), .ready(manifest))
    await harness.manager.startServer()
    harness.runner.processes.first?.exit(.signaled(6))
    await waitUntil(within: .seconds(5)) { harness.manager.serverRestart != nil }
    await harness.manager.waitForScheduledRestarts()

    #expect(
      harness.manager.server == .failed(.restartLimitReached(attempts: 5, lastExit: .exited(3))))
    #expect(harness.runner.launches.count == 6)
    let backoff = harness.clock.recordedSleeps.filter { $0 >= .seconds(1) }
    #expect(backoff == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)])
  }

  @Test("with restarts off, a crash stays crashed")
  func noRestart() async throws {
    let harness = try LocalServerHarness { $0.restartOnCrash = false }
    defer { harness.cleanUp() }
    harness.runner.script(announces(6767))
    harness.probe.answer(try loopback(6767), .ready(manifest))
    await harness.manager.startServer()
    harness.runner.processes.first?.exit(.exited(1))
    await waitUntil(within: .seconds(5)) { harness.manager.server.endpoint == nil }
    #expect(harness.manager.server == .crashed(.exited(1), restartAt: nil))
    #expect(harness.manager.serverRestart == nil)
    #expect(harness.runner.launches.count == 1)
  }

  @Test("start on launch starts a server when none is running")
  func startOnLaunch() async throws {
    let harness = try LocalServerHarness { $0.startOnLaunch = true }
    defer { harness.cleanUp() }
    harness.runner.script(announces(6767))
    harness.probe.answer(try loopback(6767), .ready(manifest))
    var triggers: [LocalServerStartTrigger] = []
    harness.manager.onServerReady = { triggers.append($1) }
    await harness.manager.launch()
    #expect(harness.manager.server.ownership == .owned)
    #expect(triggers == [.launch])
  }

  @Test("the App Store edition never spawns")
  func unavailable() async throws {
    let harness = try LocalServerHarness(capability: .unavailable(.appSandbox))
    defer { harness.cleanUp() }
    await harness.manager.launch()
    await harness.manager.startServer()
    await harness.manager.startHost(serverURL: try loopback(6767))
    #expect(harness.manager.server == .unavailable(.appSandbox))
    #expect(harness.manager.host == .unavailable(.appSandbox))
    #expect(harness.runner.launches.isEmpty)
    #expect(!harness.manager.hasProcessesToStopOnQuit)
  }

  @Test("a missing CLI fails with the places searched")
  func missingCLI() async throws {
    let harness = try LocalServerHarness { $0.cliPath = "/nope/omnigent" }
    defer { harness.cleanUp() }
    await harness.manager.startServer()
    #expect(harness.manager.server == .failed(.configuredCLIInvalid(path: "/nope/omnigent")))
    #expect(harness.manager.cli == .missing(.configuredCLIInvalid(path: "/nope/omnigent")))
  }
}
