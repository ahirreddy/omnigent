import Foundation
import Testing

@testable import OmnigentDesktop

@Suite("Local host mode")
@MainActor
struct LocalHostModeTests {
  @Test("hosting needs confirmation; declining spawns nothing")
  func declined() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    var asked: [URL] = []
    harness.manager.confirmHostMode = { url in
      asked.append(url)
      return false
    }
    let url = try loopback(6767)
    await harness.manager.startHost(serverURL: url)
    #expect(asked == [url])
    #expect(harness.manager.host == .stopped)
    #expect(harness.runner.launches.isEmpty)
  }

  /// A harness whose local server is running on port 6767.
  private func harnessWithServer() async throws -> (LocalServerHarness, URL) {
    let harness = try LocalServerHarness()
    let url = try loopback(6767)
    harness.runner.script(announces(6767))
    harness.probe.answer(
      url, .ready(LocalServerManifest(manifestVersion: 1, serverVersion: "0.9.0")))
    await harness.manager.startServer()
    #expect(harness.manager.server.endpoint?.url == url)
    return (harness, url)
  }

  private func hostLaunches(_ harness: LocalServerHarness) -> Int {
    harness.runner.launches.filter { $0.arguments.first == "host" }.count
  }

  @Test("this Mac hosts its own server without asking, until the user stops it")
  func ownServerNeverAsks() async throws {
    let (harness, url) = try await harnessWithServer()
    defer { harness.cleanUp() }
    harness.manager.confirmHostMode = { _ in
      Issue.record("asked to host for this Mac's own server")
      return false
    }
    let connected: FakeRunner.Behavior = { process in
      process.print("\u{2713} Connected as 'mac'.")
    }

    // A first launch hosts with nothing to click.
    harness.runner.script(connected)
    await harness.manager.resumeHost(serverURL: url)
    #expect(harness.manager.host == .connected(serverURL: url, .owned))
    #expect(hostLaunches(harness) == 1)

    // Quitting isn't stopping, so the next launch hosts again.
    await harness.manager.disconnectHost()
    harness.runner.script(connected)
    await harness.manager.resumeHost(serverURL: url)
    #expect(hostLaunches(harness) == 2)

    // The user's own stop holds across launches until the user starts it again.
    await harness.manager.stopHost()
    #expect(harness.manager.preferences.localHostingStopped)
    await harness.manager.resumeHost(serverURL: url)
    #expect(harness.manager.host == .stopped)
    #expect(hostLaunches(harness) == 2)

    harness.runner.script(connected)
    await harness.manager.startHost(serverURL: url)
    #expect(!harness.manager.preferences.localHostingStopped)
    #expect(hostLaunches(harness) == 3)
    await harness.manager.stopOwnedProcesses()
  }

  @Test("other servers ask first, and are never hosted for on their own")
  func otherServersAsk() async throws {
    let (harness, _) = try await harnessWithServer()
    defer { harness.cleanUp() }
    var asked: [URL] = []
    harness.manager.confirmHostMode = { url in
      asked.append(url)
      return false
    }
    let remote = try #require(URL(string: "https://omnigent.example.com"))
    // A tunnel to another machine also looks like loopback.
    let tunnel = try loopback(7000)
    await harness.manager.resumeHost(serverURL: remote)
    await harness.manager.resumeHost(serverURL: tunnel)
    #expect(asked.isEmpty)
    await harness.manager.startHost(serverURL: remote)
    await harness.manager.startHost(serverURL: tunnel)
    #expect(asked == [remote, tunnel])
    #expect(hostLaunches(harness) == 0)
    await harness.manager.stopOwnedProcesses()
  }

  @Test("a confirmed host connects, and quit stops it")
  func connects() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.manager.confirmHostMode = { _ in true }
    harness.runner.script({ process in
      process.print("\u{2713} Connected as 'mac' (abc), 0 live runner(s).")
    })
    let url = try loopback(6767)
    await harness.manager.startHost(serverURL: url)
    #expect(harness.manager.host == .connected(serverURL: url, .owned))
    let launch = try #require(harness.runner.launches.first)
    #expect(
      launch.arguments == ["host", "--server", "http://127.0.0.1:6767", "--non-interactive"])
    #expect(try harness.records.read(.host)?.serverURL == url)

    await harness.manager.stopOwnedProcesses()
    #expect(harness.runner.processes.first?.signals == [.interrupt])
    #expect(harness.manager.host == .stopped)
  }

  @Test("a daemon already hosting for the server is adopted and left running on quit")
  func adoptsDaemon() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.manager.confirmHostMode = { _ in true }
    harness.runner.script({ process in
      process.print("Error: A host daemon is already running for this server (pid 77).")
      process.exit(.exited(1))
    })
    let url = try loopback(6767)
    await harness.manager.startHost(serverURL: url)
    #expect(harness.manager.host == .connected(serverURL: url, .adopted))
    #expect(!harness.manager.hasProcessesToStopOnQuit)
    await harness.manager.stopOwnedProcesses()
    #expect(harness.runner.launches.count == 1)
  }

  @Test("an authentication failure asks the user to sign in")
  func authentication() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.manager.confirmHostMode = { _ in true }
    harness.runner.script({ process in
      process.print("Authentication failed: run `omnigent login https://x`", stream: .standardError)
      process.exit(.exited(1))
    })
    let url = try url("https://omnigent.example.com")
    await harness.manager.startHost(serverURL: url)
    guard case .failed(.hostAuthenticationRequired(let serverURL, _)) = harness.manager.host else {
      Issue.record("expected an authentication failure, got \(harness.manager.host)")
      return
    }
    #expect(serverURL == url)
  }

  @Test("a remote server the CLI is not signed in to runs omnigent login first")
  func signsInBeforeHosting() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.manager.confirmHostMode = { _ in true }
    harness.probe.answerSignIn(.signInNeeded)
    let tokens = harness.root.appending(path: ".omnigent")
    try FileManager.default.createDirectory(at: tokens, withIntermediateDirectories: true)
    try Data(#"{"https://omnigent.example.com":{"token":"tok","expires_at":1}}"#.utf8)
      .write(to: tokens.appending(path: "auth_tokens.json"))
    harness.runner.script(
      { process in process.exit(.exited(0)) },
      { process in process.print("\u{2713} Connected as 'mac' (abc), 0 live runner(s).") })
    let url = try url("https://omnigent.example.com/")
    await harness.manager.startHost(serverURL: url)
    #expect(harness.runner.launches.map(\.arguments.first) == ["login", "host"])
    #expect(harness.runner.launches.first?.arguments.last == "https://omnigent.example.com/")
    #expect(harness.probe.signInBearers == [nil], "an expired token is not sent")
    #expect(harness.manager.host == .connected(serverURL: url, .owned))
  }

  @Test("a sign-in that does not complete stops before hosting")
  func signInFails() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.manager.confirmHostMode = { _ in true }
    harness.probe.answerSignIn(.signInNeeded)
    harness.runner.script({ process in process.exit(.exited(1)) })
    let url = try url("https://omnigent.example.com")
    await harness.manager.startHost(serverURL: url)
    #expect(harness.runner.launches.count == 1)
    guard case .failed(.hostAuthenticationRequired(let serverURL, _)) = harness.manager.host else {
      Issue.record("expected an authentication failure, got \(harness.manager.host)")
      return
    }
    #expect(serverURL == url)
  }

  @Test("a loopback or signed-in server hosts without a sign-in")
  func noSignInNeeded() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.manager.confirmHostMode = { _ in true }
    harness.probe.answerSignIn(.signInNeeded)
    harness.runner.script({ process in
      process.print("\u{2713} Connected as 'mac' (abc), 0 live runner(s).")
    })
    await harness.manager.startHost(serverURL: try loopback(6767))
    #expect(harness.runner.launches.map(\.arguments.first) == ["host"])
    #expect(harness.probe.signInBearers.isEmpty)
  }

  @Test("without a server URL hosting fails clearly")
  func noServer() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    await harness.manager.startHost()
    #expect(harness.manager.host == .failed(.noServerForHost))
  }

  @Test("a host left running by an earlier launch is stopped at launch")
  func stopsLeftoverHost() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    let identity = LocalProcessIdentity(pid: 7_171, startMicroseconds: 5)
    harness.runner.addExternal(identity)
    try harness.records.write(
      LocalServerRecord(
        kind: .host, process: identity, serverURL: try loopback(6767), commandLine: "omnigent host")
    )
    await harness.manager.launch()
    #expect(harness.runner.externalSignals.map(\.0) == [7_171])
    #expect(try harness.records.read(.host) == nil)
  }
}
