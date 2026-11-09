import Foundation

/// Spawning, watching and stopping processes, shared by the server and the host.
extension LocalServerManager {
  /// Environment variables never passed to children: Xcode's dylib injection, XPC and
  /// CoreFoundation bookkeeping, and the sandbox marker.
  static let droppedEnvironmentPrefixes = [
    "DYLD_", "__XPC_", "XPC_", "__CF", "APP_SANDBOX_", "OS_ACTIVITY_", "FORCE_COLOR",
    "CLICOLOR_FORCE",
  ]

  /// The children's environment: the app's, minus `droppedEnvironmentPrefixes`, with the login
  /// shell's `PATH` (so host-mode agents find `git`, `claude`, `codex` and friends), unbuffered
  /// Python, logs mirrored to standard error without color, and the data directory.
  /// - Parameter resolution: The CLI.
  /// - Returns: The environment.
  func childEnvironment(_ resolution: LocalCLIResolution) -> [String: String] {
    var environment = dependencies.environment.filter { key, _ in
      !Self.droppedEnvironmentPrefixes.contains { key.hasPrefix($0) }
    }
    let shellPath = resolution.loginShellPath ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    let known = LocalCLIDiscovery(
      configuredPath: nil, developmentCheckout: nil, system: dependencies.cliSystem
    ).knownDirectories
    var directories: [String] = []
    let candidates =
      [resolution.command.executable.deletingLastPathComponent().path]
      + shellPath.split(separator: ":").map(String.init) + known
    for directory in candidates where !directory.isEmpty && !directories.contains(directory) {
      directories.append(directory)
    }
    environment["PATH"] = directories.joined(separator: ":")
    environment["HOME"] = environment["HOME"] ?? dependencies.homeDirectory.path
    environment["PYTHONUNBUFFERED"] = "1"
    // The CLI mirrors its process logs only to a terminal, or to the descriptor named by
    // OMNIGENT_LOG_TTY_FD. Naming standard error (the pipe) streams them into the log window;
    // the CLI still writes its own log file.
    environment["OMNIGENT_LOG_TO_STDERR"] = "1"
    environment["OMNIGENT_LOG_TTY_FD"] = "2"
    environment["NO_COLOR"] = "1"
    environment["OMNIGENT_DATA_DIR"] = dataDirectory.path
    return environment
  }

  /// The features for this app's own server, adding one-click agent installs: the server and
  /// its host are this Mac, for this user. An explicit `-harness_install` still wins.
  static func serverFeatures(_ existing: String?) -> String {
    [existing, "harness_install"].compactMap { $0 }.filter { !$0.isEmpty }
      .joined(separator: ",")
  }

  /// Spawns a process and starts consuming its output and exit.
  /// - Parameters:
  ///   - launch: What to run.
  ///   - kind: Server or host.
  ///   - log: Where its output goes.
  ///   - onLine: Called for each complete output line.
  ///   - onExit: Called once when it exits, after its output is read.
  /// - Returns: The run.
  /// - Throws: `LocalServerError.spawnFailed` or `.spawnSetupFailed`.
  func spawn(
    _ launch: LocalProcessLaunch, kind: LocalServerRecord.Kind, log: LocalProcessLog,
    onLine: @escaping (ProcessRun, String) -> Void,
    onExit: @escaping (ProcessRun, LocalProcessExit) -> Void
  ) throws(LocalServerError) -> ProcessRun {
    let handle = try dependencies.runner.launch(launch)
    let run = ProcessRun(
      kind: kind, ownership: .owned, handle: handle, pid: handle.pid,
      identity: dependencies.runner.identity(of: handle.pid), commandLine: launch.commandLine)
    log.appendEvent("Started \(launch.commandLine) (PID \(handle.pid)).")
    let output = Task {
      for await chunk in handle.output {
        for line in log.append(chunk) { onLine(run, line) }
      }
      log.flush()
      run.outputFinished = true
    }
    let exit = Task {
      let exit = await handle.waitForExit()
      // Read output up to the exit so error messages include the last lines, but not forever:
      // a grandchild can hold the pipes open after the process itself exited.
      await firstOf(output, orSeconds: 2)
      run.exit = exit
      log.appendEvent("The process \(exit.summary).")
      onExit(run, exit)
    }
    run.tasks = [output, exit]
    return run
  }

  /// Wraps a process the app did not spawn in this launch and watches for its exit.
  /// - Parameters:
  ///   - kind: Server or host.
  ///   - ownership: `.recovered` or `.adopted`.
  ///   - identity: Its identity.
  ///   - commandLine: For logs.
  ///   - onExit: Called once when it exits.
  /// - Returns: The run.
  func watch(
    kind: LocalServerRecord.Kind, ownership: LocalServiceOwnership,
    identity: LocalProcessIdentity, commandLine: String,
    onExit: @escaping (ProcessRun, LocalProcessExit) -> Void
  ) -> ProcessRun {
    let run = ProcessRun(
      kind: kind, ownership: ownership, handle: nil, pid: identity.pid, identity: identity,
      commandLine: commandLine)
    run.outputFinished = true
    let runner = dependencies.runner
    run.tasks = [
      Task {
        await runner.waitForExit(ofUnrelated: identity.pid)
        guard !Task.isCancelled else { return }
        run.exit = .unknown
        onExit(run, .unknown)
      }
    ]
    return run
  }

  /// SIGINT (as Control-C in Terminal), then SIGKILL after `timing.stopGrace`, waiting for the
  /// exit each time.
  /// - Parameters:
  ///   - run: The process.
  ///   - log: Where to note escalation.
  /// - Returns: Success once it exited.
  func terminate(_ run: ProcessRun, log: LocalProcessLog) async -> Result<Void, LocalServerError> {
    run.stopRequested = true
    for (signal, grace) in [
      (LocalProcessSignal.interrupt, dependencies.timing.stopGrace), (.kill, .seconds(5)),
    ] {
      guard run.exit == nil else { return .success(()) }
      if signal == .kill {
        log.appendEvent("Still running after \(grace.components.seconds) seconds; killing it.")
      }
      do {
        try send(signal, to: run)
      } catch {
        return .failure(error)
      }
      if await waitForExit(run, within: grace) { return .success(()) }
    }
    return .failure(
      .commandFailed(
        command: "kill -9 \(run.pid)", exit: nil, output: "the process did not exit"))
  }

  /// Signals a run's process group. For a process the app did not spawn this launch, the
  /// identity is checked first, so a reused PID is never signaled.
  func send(_ signal: LocalProcessSignal, to run: ProcessRun) throws(LocalServerError) {
    if let handle = run.handle {
      try handle.send(signal)
      return
    }
    guard let identity = run.identity, dependencies.runner.identity(of: run.pid) == identity
    else {
      run.exit = run.exit ?? .unknown
      return
    }
    try dependencies.runner.send(signal, toGroupOf: run.pid)
  }

  /// Polls until the run has exited.
  /// - Returns: Whether it exited within `duration`.
  func waitForExit(_ run: ProcessRun, within duration: Duration) async -> Bool {
    let clock = dependencies.clock
    let deadline = clock.now + duration
    while run.exit == nil {
      guard clock.now < deadline else { return false }
      do {
        try await clock.sleep(for: .milliseconds(100))
      } catch {
        return run.exit != nil
      }
    }
    return true
  }

  /// Runs a short CLI command such as `server stop`.
  /// - Parameters:
  ///   - subcommand: Arguments after the CLI's prefix.
  ///   - log: Where to log it.
  /// - Returns: Success on exit status 0.
  func runCLI(_ subcommand: [String], log: LocalProcessLog) async -> Result<
    Void, LocalServerError
  > {
    guard let resolution = await resolveCLI() else { return .failure(cliError) }
    let launch = LocalProcessLaunch(
      executable: resolution.command.executable,
      arguments: resolution.command.arguments(subcommand),
      environment: childEnvironment(resolution), workingDirectory: dependencies.homeDirectory)
    log.appendEvent("Running \(launch.commandLine).")
    do {
      let result = try await LocalCommand.run(
        launch, runner: dependencies.runner, clock: dependencies.clock,
        timeout: dependencies.timing.command)
      for line in result.combinedOutput.split(whereSeparator: \.isNewline) {
        log.appendEvent(String(line))
      }
      guard result.exit.isSuccess else {
        return .failure(
          .commandFailed(
            command: launch.commandLine, exit: result.exit, output: result.combinedOutput))
      }
      return .success(())
    } catch {
      return .failure(error)
    }
  }

  /// Writes a record, reporting a failure without stopping the process: the record only helps
  /// a later launch.
  func writeRecord(for run: ProcessRun, log: LocalProcessLog) {
    guard let identity = run.identity else {
      // The process exited before its start time could be read; there is nothing to find later.
      log.appendEvent("PID \(run.pid) exited before it could be recorded.")
      return
    }
    let record = LocalServerRecord(
      kind: run.kind, process: identity, port: run.port, serverURL: run.serverURL,
      commandLine: run.commandLine)
    do {
      try dependencies.records.write(record)
    } catch {
      note(error, in: log)
    }
  }

  /// Removes a record, reporting a failure.
  func removeRecord(_ kind: LocalServerRecord.Kind, log: LocalProcessLog) {
    do {
      try dependencies.records.remove(kind)
    } catch {
      note(error, in: log)
    }
  }
}

/// Waits for `task` to finish or for `seconds` of real time, whichever comes first.
func firstOf(_ task: Task<Void, Never>, orSeconds seconds: Int) async {
  await withTaskGroup(of: Void.self) { group in
    group.addTask { await task.value }
    group.addTask {
      do {
        try await Task.sleep(for: .seconds(seconds))
      } catch {
        return  // Cancelled because the task finished first.
      }
    }
    await group.next()
    group.cancelAll()
  }
}
