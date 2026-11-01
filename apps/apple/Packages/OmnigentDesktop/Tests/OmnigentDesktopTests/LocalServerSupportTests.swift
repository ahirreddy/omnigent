import Foundation
import Testing

@testable import OmnigentDesktop

@Suite("CLI discovery")
struct LocalCLIDiscoveryTests {
  private func system(executables: Set<String>, path: String?) -> LocalCLIDiscovery.System {
    LocalCLIDiscovery.System(
      homeDirectory: URL(filePath: "/Users/me"), isExecutableFile: { executables.contains($0) },
      loginShellPath: { () throws(LocalServerError) in
        guard let path else {
          throw .commandFailed(command: "zsh -l", exit: .exited(1), output: "no profile")
        }
        return path
      })
  }

  @Test("a configured path wins and an invalid one is an error, not a fallback")
  func configured() async throws {
    let found = try await LocalCLIDiscovery(
      configuredPath: "/opt/tools/omnigent", developmentCheckout: nil,
      system: system(executables: ["/opt/tools/omnigent", "/usr/local/bin/omnigent"], path: nil)
    ).discover()
    #expect(found.command.source == .configured)
    #expect(found.command.executable.path == "/opt/tools/omnigent")
    #expect(found.warnings.count == 1)

    await #expect(throws: LocalServerError.configuredCLIInvalid(path: "/missing")) {
      try await LocalCLIDiscovery(
        configuredPath: "/missing", developmentCheckout: nil,
        system: system(executables: ["/usr/local/bin/omnigent"], path: nil)
      ).discover()
    }
  }

  @Test("login-shell PATH, then known locations, then the omni alias, then the checkout")
  func order() async throws {
    let onPath = try await LocalCLIDiscovery(
      configuredPath: nil, developmentCheckout: nil,
      system: system(
        executables: ["/Users/me/.pyenv/shims/omnigent", "/Users/me/.local/bin/omnigent"],
        path: "/Users/me/.pyenv/shims:/usr/bin")
    ).discover()
    #expect(onPath.command.source == .loginShellPath)
    #expect(onPath.command.executable.path == "/Users/me/.pyenv/shims/omnigent")
    #expect(onPath.loginShellPath == "/Users/me/.pyenv/shims:/usr/bin")

    let known = try await LocalCLIDiscovery(
      configuredPath: nil, developmentCheckout: nil,
      system: system(executables: ["/opt/homebrew/bin/omni"], path: "/usr/bin")
    ).discover()
    #expect(known.command.source == .knownLocation)
    #expect(known.command.executable.path == "/opt/homebrew/bin/omni")

    let checkout = try await LocalCLIDiscovery(
      configuredPath: nil, developmentCheckout: URL(filePath: "/src/omnigent"),
      system: system(executables: ["/src/omnigent/.venv/bin/omnigent"], path: "/usr/bin")
    ).discover()
    #expect(checkout.command.source == .developmentCheckout)
  }

  @Test("nothing found lists every place searched")
  func notFound() async throws {
    do {
      _ = try await LocalCLIDiscovery(
        configuredPath: nil, developmentCheckout: nil, system: system(executables: [], path: "/a")
      ).discover()
      Issue.record("expected cliNotFound")
    } catch {
      guard case .cliNotFound(let searched) = error else {
        Issue.record("expected cliNotFound, got \(error)")
        return
      }
      #expect(searched.first == "/a/omnigent")
      #expect(searched.contains("/Users/me/.local/bin/omnigent"))
      #expect(searched.contains("/opt/homebrew/bin/omni"))
      #expect(error.message.contains("uv tool install omnigent"))
    }
  }

  @Test("the login PATH is read between markers, ignoring profile noise")
  func loginShellParse() {
    let output = "Welcome!\n\n\(LoginShell.marker)/a:/b\(LoginShell.marker)\nbye"
    #expect(LoginShell.parse(output) == "/a:/b")
    #expect(LoginShell.parse("no markers") == nil)
    #expect(LoginShell.parse("\(LoginShell.marker)\(LoginShell.marker)") == nil)
  }
}

@Suite("Local server parsing")
struct LocalServerParsingTests {
  @Test("the CLI's startup line announces the port")
  @MainActor
  func announcedPort() {
    #expect(
      LocalServerManager.announcedPort(in: "Starting omnigent server on 127.0.0.1:6767") == 6767)
    #expect(LocalServerManager.announcedPort(in: "Starting omnigent server on [::1]:7001") == 7001)
    #expect(LocalServerManager.announcedPort(in: "  database:  sqlite") == nil)
    #expect(LocalServerManager.announcedPort(in: "Starting omnigent server on host:99999") == nil)
  }

  @Test("the canonical pidfile is two lines, PID then port; anything else is no record")
  func canonicalRecord() {
    #expect(CanonicalServerRecord.parse("123\n6767\n")?.port == 6767)
    #expect(CanonicalServerRecord.parse("123\n6767\nextra")?.pid == 123)
    #expect(CanonicalServerRecord.parse("123") == nil)
    #expect(CanonicalServerRecord.parse("abc\n6767") == nil)
    #expect(CanonicalServerRecord.parse("123\n0") == nil)
  }

  @Test("manifests decode the fields the shell uses and ignore the rest")
  func manifest() throws {
    let body = Data(
      #"{"manifest_version": 2, "server_version": "1.2.3", "auth": {"mode": "none"}, "new": 1}"#
        .utf8)
    let manifest = try LocalServerManifest.decode(body)
    #expect(
      manifest == LocalServerManifest(manifestVersion: 2, serverVersion: "1.2.3", authMode: "none"))
    #expect(throws: ProbeProblem.self) { try LocalServerManifest.decode(Data("[]".utf8)) }
    #expect(throws: ProbeProblem.self) {
      try LocalServerManifest.decode(Data(#"{"server_version": "1"}"#.utf8))
    }
  }

  @Test("health must be Omnigent's {status: ok}")
  func health() {
    #expect(URLSessionLocalServerProbe.healthProblem(Data(#"{"status":"ok"}"#.utf8)) == nil)
    #expect(URLSessionLocalServerProbe.healthProblem(Data(#"{"status":"up"}"#.utf8)) != nil)
    #expect(URLSessionLocalServerProbe.healthProblem(Data("<html>".utf8)) != nil)
  }

  @Test("restart backoff doubles, caps attempts, and resets after stable uptime")
  func restartPolicy() {
    let policy = LocalRestartPolicy()
    #expect(
      (1...5).compactMap(policy.delay(forAttempt:)) == [1, 2, 4, 8, 16].map(Duration.seconds))
    #expect(policy.delay(forAttempt: 6) == nil)
    #expect(policy.attempt(after: 3, uptime: .seconds(5)) == 4)
    #expect(policy.attempt(after: 3, uptime: nil) == 4)
    #expect(policy.attempt(after: 3, uptime: .seconds(61)) == 1)
  }

  @Test("sandboxed processes cannot spawn")
  func capability() {
    #expect(LocalServerCapability.detect(environment: [:]) == .available)
    #expect(
      LocalServerCapability.detect(environment: ["APP_SANDBOX_CONTAINER_ID": "x"])
        == .unavailable(.appSandbox))
  }
}

@Suite("Local process log")
@MainActor
struct LocalProcessLogTests {
  @Test("lines split across chunks, per stream, with CR and ANSI removed")
  func splitting() {
    let log = LocalProcessLog()
    #expect(log.append(LocalProcessOutput(.standardOutput, Data("hel".utf8))).isEmpty)
    log.append(LocalProcessOutput(.standardError, Data("err\r\n".utf8)))
    let finished = log.append(
      LocalProcessOutput(.standardOutput, Data("lo \u{1B}[32mgreen\u{1B}[0m\nnext".utf8)))
    #expect(finished == ["hello green"])
    log.flush()
    #expect(log.lines.map(\.text) == ["err", "hello green", "next"])
    #expect(log.lines.map(\.source) == [.standardError, .standardOutput, .standardOutput])
  }

  @Test("keeps at most its capacity, oldest dropped")
  func capacity() {
    let log = LocalProcessLog(capacity: 10)
    for index in 0..<30 { log.appendEvent("line \(index)") }
    #expect(log.lines.count <= 11)
    #expect(log.lines.last?.text == "line 29")
    #expect(log.droppedLineCount + log.lines.count == 30)
    #expect(Set(log.lines.map(\.id)).count == log.lines.count)
  }

  @Test("very long lines are cut")
  func longLines() {
    let log = LocalProcessLog()
    let long = String(repeating: "x", count: LocalProcessLog.maximumLineLength + 50)
    log.append(LocalProcessOutput(.standardOutput, Data(long.utf8)))
    #expect(log.lines.count == 1)
    #expect(log.lines.first?.text.hasSuffix("[line cut]") == true)
  }
}

@Suite("Local server records")
struct LocalServerRecordTests {
  @Test("records round-trip, are private to the user, and a missing one is nil")
  func roundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "lsm-\(UUID())")
    defer {
      do {
        try FileManager.default.removeItem(at: directory)
      } catch {
        Issue.record("cleanup failed: \(error)")
      }
    }
    let store = LocalServerRecordStore(directory: directory)
    #expect(try store.read(.server) == nil)
    let record = LocalServerRecord(
      kind: .server, process: LocalProcessIdentity(pid: 9, startMicroseconds: 10), port: 6767,
      commandLine: "omnigent server", recordedAt: Date(timeIntervalSince1970: 1_000))
    try store.write(record)
    #expect(try store.read(.server) == record)
    let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL(.server).path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
    try store.remove(.server)
    try store.remove(.server)
    #expect(try store.read(.server) == nil)

    try Data("{".utf8).write(to: store.fileURL(.host))
    #expect(throws: LocalServerError.self) { try store.read(.host) }
  }
}

@Suite("posix_spawn runner")
struct PosixSpawnProcessRunnerTests {
  @Test("captures both pipes, reports the exit, and resets the environment")
  func spawn() async throws {
    let runner = PosixSpawnProcessRunner()
    let process = try runner.launch(
      LocalProcessLaunch(
        executable: URL(filePath: "/bin/sh"),
        arguments: ["-c", "echo out; echo err >&2; echo \"$ONLY\"; exit 3"],
        environment: ["ONLY": "this"], workingDirectory: URL(filePath: "/")))
    var stdout = Data()
    var stderr = Data()
    for await chunk in process.output {
      if chunk.stream == .standardOutput {
        stdout.append(chunk.data)
      } else {
        stderr.append(chunk.data)
      }
    }
    #expect(await process.waitForExit() == .exited(3))
    #expect(String(bytes: stdout, encoding: .utf8) == "out\nthis\n")
    #expect(String(bytes: stderr, encoding: .utf8) == "err\n")
    #expect(runner.identity(of: process.pid) == nil)
  }

  @Test("signals reach the whole process group")
  func processGroup() async throws {
    let runner = PosixSpawnProcessRunner()
    let process = try runner.launch(
      LocalProcessLaunch(
        executable: URL(filePath: "/bin/sh"), arguments: ["-c", "sleep 30 & wait"],
        environment: [:]))
    let identity = try #require(runner.identity(of: process.pid))
    #expect(identity.startMicroseconds > 0)
    try process.send(.terminate)
    #expect(await process.waitForExit() == .signaled(SIGTERM))
    try process.send(.kill)  // After exit this is a no-op, not an error.
  }

  @Test("a missing executable is a spawn error")
  func missing() {
    #expect(throws: LocalServerError.spawnFailed(executable: "/nonexistent/x", errno: ENOENT)) {
      _ = try PosixSpawnProcessRunner().launch(
        LocalProcessLaunch(
          executable: URL(filePath: "/nonexistent/x"), arguments: [], environment: [:]))
    }
  }

  @Test("an unrelated process exit is observed")
  func unrelatedExit() async throws {
    let runner = PosixSpawnProcessRunner()
    let process = try runner.launch(
      LocalProcessLaunch(
        executable: URL(filePath: "/bin/sleep"), arguments: ["0.2"], environment: [:]))
    await runner.waitForExit(ofUnrelated: process.pid)
    #expect(await process.waitForExit() == .exited(0))
  }
}
