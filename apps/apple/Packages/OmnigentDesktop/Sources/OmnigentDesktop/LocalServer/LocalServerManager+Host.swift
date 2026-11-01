public import Foundation

/// Host mode: this Mac running agent work for a server.
extension LocalServerManager {
  /// The line `omnigent host` prints once its tunnel is up (`omnigent/host/connect.py`).
  static let hostConnectedMarker = "\u{2713} Connected"

  /// Asks for confirmation, then connects this Mac as a host.
  /// - Parameter serverURL: The server to host for; defaults to the running local server.
  public func startHost(serverURL: URL? = nil) async {
    guard capability.isAvailable, host.canStart else { return }
    guard let target = serverURL ?? server.endpoint?.url else {
      failHost(.noServerForHost)
      return
    }
    host = .awaitingConfirmation(serverURL: target)
    guard await confirmHostMode(target) else {
      hostLog.appendEvent("Hosting for \(target.absoluteString) was not allowed.")
      host = .stopped
      return
    }
    hostCrashes = 0
    await launchHost(target, restartAttempt: nil)
  }

  /// Disconnects this Mac. A host the app started is signaled; one it found already running is
  /// stopped with `omnigent host stop`, because the user asked.
  public func stopHost() async {
    hostRestart?.cancel()
    hostRestart = nil
    if let run = hostRun {
      run.stopRequested = true
      host = .stopping
      hostLog.appendEvent("Stopping the host.")
      let result = await terminate(run, log: hostLog)
      run.cancelTasks()
      hostRun = nil
      removeRecord(.host, log: hostLog)
      finishHostStop(result)
    } else if case .connected(let url, .adopted) = host {
      host = .stopping
      finishHostStop(
        await runCLI(["host", "stop", "--server", url.absoluteString], log: hostLog))
    } else if host.canStop || host.canStart {
      host = .stopped
    }
  }

  private func finishHostStop(_ result: Result<Void, LocalServerError>) {
    switch result {
    case .success: host = .stopped
    case .failure(let error): failHost(error)
    }
  }

  private func launchHost(_ target: URL, restartAttempt: Int?) async {
    guard let resolution = await resolveCLI() else {
      failHost(cliError)
      return
    }
    host = .connecting(serverURL: target)
    let launch = LocalProcessLaunch(
      executable: resolution.command.executable,
      arguments: resolution.command.arguments([
        "host", "--server", target.absoluteString, "--non-interactive",
      ]),
      environment: childEnvironment(resolution), workingDirectory: dependencies.homeDirectory)
    let run: ProcessRun
    do {
      run = try spawn(
        launch, kind: .host, log: hostLog,
        onLine: { run, line in Self.observeHostLine(line, run: run) },
        onExit: { [weak self] run, exit in self?.hostExited(run, exit) })
    } catch {
      failHost(error)
      return
    }
    run.serverURL = target
    hostRun = run
    writeRecord(for: run, log: hostLog)
    await finishHostLaunch(run, target: target, restartAttempt: restartAttempt)
  }

  private func finishHostLaunch(_ run: ProcessRun, target: URL, restartAttempt: Int?) async {
    let outcome = await waitForHostConnected(run, target: target)
    if run.stopRequested { return }  // `stopHost` owns the state now.
    if case .success = outcome, !run.alreadyHosted {
      run.readyAt = dependencies.clock.now
      host = .connected(serverURL: target, .owned)
      return
    }
    if run.exit == nil, case .failure(let error) = await terminate(run, log: hostLog) {
      note(error, in: hostLog)
    }
    run.cancelTasks()
    if hostRun === run { hostRun = nil }
    removeRecord(.host, log: hostLog)
    switch outcome {
    case .success:
      hostLog.appendEvent("A host was already connected to \(target.absoluteString); using it.")
      host = .connected(serverURL: target, .adopted)
    case .failure(let error) where restartAttempt != nil:
      hostLog.appendEvent(error.message)
      hostCrashed(target, run.exit ?? .unknown, uptime: nil)
    case .failure(let error):
      failHost(error)
    }
  }

  /// Polls until the host prints its connected line, exits, or time runs out. A conflict with a
  /// daemon already hosting for the server counts as success with `run.alreadyHosted` set.
  private func waitForHostConnected(_ run: ProcessRun, target: URL) async -> Result<
    Void, LocalServerError
  > {
    let clock = dependencies.clock
    let deadline = clock.now + dependencies.timing.hostConnect
    while !run.connected, !run.stopRequested {
      if let exit = run.exit {
        if run.alreadyHosted { return .success(()) }
        let lines = hostLog.lastProcessLines(10)
        let text = lines.joined(separator: "\n")
        if Self.isAuthenticationFailure(text) {
          return .failure(.hostAuthenticationRequired(serverURL: target, detail: text))
        }
        return .failure(.exitedBeforeReady(exit, lastLines: lines))
      }
      guard clock.now < deadline else {
        let seconds = Int(dependencies.timing.hostConnect.components.seconds)
        return .failure(
          .readinessTimedOut(seconds: seconds, lastProblem: "the host never reported connected"))
      }
      do {
        try await clock.sleep(for: dependencies.timing.pollInterval)
      } catch {
        break
      }
    }
    return run.stopRequested
      ? .failure(.commandFailed(command: run.commandLine, exit: nil, output: "stopped"))
      : .success(())
  }

  static func observeHostLine(_ line: String, run: ProcessRun) {
    if line.contains(hostConnectedMarker) { run.connected = true }
    let lowered = line.lowercased()
    if lowered.contains("already running for this server")
      || lowered.contains("host daemon is already running")
    {
      run.alreadyHosted = true
    }
  }

  /// Mirrors `isAuthError` in the Electron shell's `server_manager.js`.
  static func isAuthenticationFailure(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return ["authentication failed", "http 401", "unauthor", "login page", "omnigent login"]
      .contains { lowered.contains($0) }
  }

  private func hostExited(_ run: ProcessRun, _ exit: LocalProcessExit) {
    guard hostRun === run, !run.stopRequested, let readyAt = run.readyAt,
      let target = run.serverURL
    else { return }
    run.cancelTasks()
    hostRun = nil
    removeRecord(.host, log: hostLog)
    hostCrashed(target, exit, uptime: dependencies.clock.now - readyAt)
  }

  private func hostCrashed(_ target: URL, _ exit: LocalProcessExit, uptime: Duration?) {
    let policy = dependencies.restartPolicy
    guard preferences.restartOnCrash else {
      host = .crashed(serverURL: target, exit, restartAt: nil)
      reportIssue(.exitedBeforeReady(exit, lastLines: hostLog.lastProcessLines(10)))
      return
    }
    hostCrashes = policy.attempt(after: hostCrashes, uptime: uptime)
    guard let delay = policy.delay(forAttempt: hostCrashes) else {
      failHost(.restartLimitReached(attempts: hostCrashes - 1, lastExit: exit))
      return
    }
    let attempt = hostCrashes
    host = .crashed(
      serverURL: target, exit, restartAt: Date().addingTimeInterval(delay.timeInterval))
    hostLog.appendEvent("Reconnecting in \(delay.components.seconds) s (attempt \(attempt)).")
    let clock = dependencies.clock
    hostRestart = Task { [weak self] in
      do {
        try await clock.sleep(for: delay)
      } catch {
        return  // Cancelled by Stop Host or quit.
      }
      guard let self, case .crashed = host else { return }
      // Consent was given for this session; a restart does not ask again.
      await launchHost(target, restartAttempt: attempt)
    }
  }
}
