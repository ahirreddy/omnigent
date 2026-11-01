import Foundation

/// The local server: start, readiness, crashes, restarts and stop.
extension LocalServerManager {
  /// How waiting for readiness ended.
  enum ServerReadiness {
    case ready(LocalServerEndpoint)
    /// The canonical CLI found a healthy server and exited 0 to let it be reused.
    case reuseExisting
    case failed(LocalServerError)
    case stopRequested
  }

  /// Starts the local server, or reuses one already running.
  /// - Parameter trigger: Why. `.user` offers to open a window when ready.
  public func startServer(trigger: LocalServerStartTrigger = .user) async {
    guard capability.isAvailable else { return }
    if case .restart = trigger {
      guard case .crashed = server else { return }
    } else {
      guard server.canStart || server == .checking else { return }
      serverCrashes = 0
    }
    server = .checking
    if let found = await existingServer() {
      adopt(found, trigger: trigger)
      return
    }
    guard let resolution = await resolveCLI() else {
      failServer(cliError)
      return
    }
    if let port = preferences.port {
      do {
        guard try dependencies.runner.isLoopbackPortAvailable(port) else {
          failServer(.portUnavailable(port: port))
          return
        }
      } catch {
        failServer(error)
        return
      }
    }
    server = .starting(trigger)
    await spawnServer(resolution, trigger: trigger)
  }

  /// Stops the server. One the app started is signaled; one started outside the app is stopped
  /// with `omnigent server stop`, because the user asked. A host the app started for this server
  /// is stopped first, since it cannot work without it.
  public func stopServer() async {
    serverRestart?.cancel()
    serverRestart = nil
    guard let run = serverRun else {
      if case .unavailable = server { return }
      server = .stopped
      return
    }
    run.stopRequested = true
    server = .stopping
    serverLog.appendEvent("Stopping the server.")
    if let url = run.port.flatMap(LocalServerEndpoint.loopbackURL(port:)),
      hostRun?.serverURL == url
    {
      await stopHost()
    }
    let result =
      run.ownership == .adopted
      ? await runCLI(["server", "stop"], log: serverLog) : await terminate(run, log: serverLog)
    run.cancelTasks()
    serverRun = nil
    if run.ownership != .adopted { removeRecord(.server, log: serverLog) }
    switch result {
    case .success: server = .stopped
    case .failure(let error): failServer(error)
    }
  }

  /// `omnigent server --host 127.0.0.1 --no-open`, plus `--port` for a fixed port.
  func serverLaunch(_ resolution: LocalCLIResolution) -> LocalProcessLaunch {
    var subcommand = ["server", "--host", "127.0.0.1", "--no-open"]
    if let port = preferences.port { subcommand += ["--port", String(port)] }
    return LocalProcessLaunch(
      executable: resolution.command.executable,
      arguments: resolution.command.arguments(subcommand),
      environment: childEnvironment(resolution), workingDirectory: dependencies.homeDirectory)
  }

  private func spawnServer(_ resolution: LocalCLIResolution, trigger: LocalServerStartTrigger)
    async
  {
    let run: ProcessRun
    do {
      run = try spawn(
        serverLaunch(resolution), kind: .server, log: serverLog,
        onLine: { run, line in
          if run.port == nil { run.port = Self.announcedPort(in: line) }
        },
        onExit: { [weak self] run, exit in self?.serverExited(run, exit) })
    } catch {
      failServer(error)
      return
    }
    run.port = preferences.port
    serverRun = run
    writeRecord(for: run, log: serverLog)
    switch await waitForServerReady(run) {
    case .ready(let endpoint):
      run.readyAt = dependencies.clock.now
      writeRecord(for: run, log: serverLog)
      server = .running(endpoint, .owned)
      serverLog.appendEvent("Ready at \(endpoint.url.absoluteString).")
      onServerReady(endpoint, trigger)
    case .reuseExisting:
      finishFailedRun(run)
      if let found = await existingServer() {
        adopt(found, trigger: trigger)
      } else {
        failServer(.exitedBeforeReady(.exited(0), lastLines: serverLog.lastProcessLines(10)))
      }
    case .failed(let error):
      if run.exit == nil, case .failure(let stopError) = await terminate(run, log: serverLog) {
        note(stopError, in: serverLog)
      }
      finishFailedRun(run)
      if case .restart = trigger {
        serverLog.appendEvent(error.message)
        serverCrashed(run.exit ?? .unknown, uptime: nil)
      } else {
        failServer(error)
      }
    case .stopRequested:
      return
    }
  }

  private func finishFailedRun(_ run: ProcessRun) {
    run.cancelTasks()
    if serverRun === run { serverRun = nil }
    removeRecord(.server, log: serverLog)
  }

  /// Polls until the server answers `/health` and its manifest, it exits, or time runs out.
  func waitForServerReady(_ run: ProcessRun) async -> ServerReadiness {
    let clock = dependencies.clock
    let deadline = clock.now + dependencies.timing.serverReadiness
    var lastProblem: String?
    while true {
      if run.stopRequested { return .stopRequested }
      if let exit = run.exit {
        if exit.isSuccess, preferences.port == nil { return .reuseExisting }
        return .failed(.exitedBeforeReady(exit, lastLines: serverLog.lastProcessLines(10)))
      }
      if run.port == nil { run.port = canonicalPort(since: run.launchDate, problem: &lastProblem) }
      if let outcome = await probeOnce(run, problem: &lastProblem) { return outcome }
      guard clock.now < deadline else {
        let seconds = Int(dependencies.timing.serverReadiness.components.seconds)
        return .failed(.readinessTimedOut(seconds: seconds, lastProblem: lastProblem))
      }
      do {
        try await clock.sleep(for: dependencies.timing.pollInterval)
      } catch {
        return .stopRequested
      }
    }
  }

  /// One probe of the run's port: an outcome when ready or rejected, `nil` to keep waiting.
  private func probeOnce(_ run: ProcessRun, problem: inout String?) async -> ServerReadiness? {
    guard let port = run.port else {
      problem = problem ?? "the server has not reported its port yet"
      return nil
    }
    guard let endpoint = LocalServerEndpoint(port: port, pid: run.pid, manifest: nil) else {
      return .failed(.spawnSetupFailed("port \(port) is out of range"))
    }
    switch await dependencies.probe.probe(endpoint.url) {
    case .ready(let manifest):
      var ready = endpoint
      ready.manifest = manifest
      return .ready(ready)
    case .notReady(let reason):
      problem = reason
      return nil
    case .rejected(let reason):
      return .failed(.notAnOmnigentServer(url: endpoint.url, detail: reason))
    }
  }

  /// The port in the CLI's pidfile when it was written after `launchDate`, which is how the
  /// canonical server reports a fallback port.
  private func canonicalPort(since launchDate: Date, problem: inout String?) -> Int? {
    do {
      guard let record = try CanonicalServerRecord.read(dataDirectory: dataDirectory),
        record.modified >= launchDate.addingTimeInterval(-2)
      else { return nil }
      return record.port
    } catch {
      problem = error.message
      return nil
    }
  }

  /// The port in the CLI's startup line `Starting omnigent server on 127.0.0.1:6767`.
  /// - Parameter line: An output line.
  /// - Returns: The port, or `nil` for any other line.
  static func announcedPort(in line: String) -> Int? {
    let marker = "Starting omnigent server on "
    guard let range = line.range(of: marker) else { return nil }
    let address = line[range.upperBound...].prefix { !$0.isWhitespace }
    guard let colon = address.lastIndex(of: ":"),
      let port = Int(address[address.index(after: colon)...]), (1...65_535).contains(port)
    else { return nil }
    return port
  }

  func serverExited(_ run: ProcessRun, _ exit: LocalProcessExit) {
    // Startup failures belong to `waitForServerReady`, deliberate stops to `stopServer`.
    guard serverRun === run, !run.stopRequested, let readyAt = run.readyAt else { return }
    run.cancelTasks()
    serverRun = nil
    guard run.ownership != .adopted else {
      serverLog.appendEvent("The server started outside Omnigent stopped.")
      server = .stopped
      return
    }
    removeRecord(.server, log: serverLog)
    serverCrashed(exit, uptime: dependencies.clock.now - readyAt)
  }

  /// Schedules a restart with backoff, or gives up.
  func serverCrashed(_ exit: LocalProcessExit, uptime: Duration?) {
    let policy = dependencies.restartPolicy
    guard preferences.restartOnCrash else {
      server = .crashed(exit, restartAt: nil)
      reportIssue(.exitedBeforeReady(exit, lastLines: serverLog.lastProcessLines(10)))
      return
    }
    serverCrashes = policy.attempt(after: serverCrashes, uptime: uptime)
    guard let delay = policy.delay(forAttempt: serverCrashes) else {
      failServer(.restartLimitReached(attempts: serverCrashes - 1, lastExit: exit))
      return
    }
    let attempt = serverCrashes
    server = .crashed(exit, restartAt: Date().addingTimeInterval(delay.timeInterval))
    serverLog.appendEvent(
      "Restarting in \(delay.components.seconds) s (attempt \(attempt) of \(policy.maximumAttempts))."
    )
    let clock = dependencies.clock
    serverRestart = Task { [weak self] in
      do {
        try await clock.sleep(for: delay)
      } catch {
        return  // Cancelled by Stop Server or quit.
      }
      await self?.startServer(trigger: .restart(attempt: attempt))
    }
  }
}

extension Duration {
  /// Seconds as a `TimeInterval`.
  var timeInterval: TimeInterval {
    let parts = components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }
}
