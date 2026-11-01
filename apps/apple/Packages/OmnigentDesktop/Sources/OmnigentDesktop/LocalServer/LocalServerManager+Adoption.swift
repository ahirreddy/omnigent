import Foundation

/// Finding servers that are already running and processes an earlier launch left behind.
extension LocalServerManager {
  /// A healthy server found through a record.
  struct FoundServer {
    var endpoint: LocalServerEndpoint
    var identity: LocalProcessIdentity
    var ownership: LocalServiceOwnership
    var commandLine: String
  }

  /// The app's own record first (a server an earlier launch started, `.recovered`), then the
  /// CLI's canonical pidfile (`.adopted`). Each must name a live process and answer the probe;
  /// a stale app record is removed, and a stale CLI record is left for the CLI.
  func existingServer() async -> FoundServer? {
    if let recovered = await recoveredServer() { return recovered }
    let record: CanonicalServerRecord?
    do {
      record = try CanonicalServerRecord.read(dataDirectory: dataDirectory)
    } catch {
      note(error, in: serverLog)
      return nil
    }
    guard let record, let identity = dependencies.runner.identity(of: record.pid),
      let endpoint = LocalServerEndpoint(port: record.port, pid: record.pid, manifest: nil)
    else { return nil }
    switch await dependencies.probe.probe(endpoint.url) {
    case .ready(let manifest):
      var ready = endpoint
      ready.manifest = manifest
      return FoundServer(
        endpoint: ready, identity: identity, ownership: .adopted,
        commandLine: "omnigent server (PID \(record.pid))")
    case .notReady(let problem), .rejected(let problem):
      serverLog.appendEvent(
        "Not using the server recorded at \(endpoint.url.absoluteString): \(problem).")
      return nil
    }
  }

  private func recoveredServer() async -> FoundServer? {
    let record: LocalServerRecord?
    do {
      record = try dependencies.records.read(.server)
    } catch {
      note(error, in: serverLog)
      return nil
    }
    guard let record else { return nil }
    let alive = dependencies.runner.identity(of: record.process.pid) == record.process
    if alive, let port = record.port,
      let endpoint = LocalServerEndpoint(port: port, pid: record.process.pid, manifest: nil),
      case .ready(let manifest) = await dependencies.probe.probe(endpoint.url)
    {
      var ready = endpoint
      ready.manifest = manifest
      return FoundServer(
        endpoint: ready, identity: record.process, ownership: .recovered,
        commandLine: record.commandLine)
    }
    if alive {
      // An earlier launch started it and it is not answering (or never reported a port), so
      // nothing can use it.
      serverLog.appendEvent(
        "Stopping an unresponsive server an earlier launch started (PID \(record.process.pid)).")
      let run = watch(
        kind: .server, ownership: .recovered, identity: record.process,
        commandLine: record.commandLine, onExit: { _, _ in })
      if case .failure(let error) = await terminate(run, log: serverLog) {
        note(error, in: serverLog)
      }
      run.cancelTasks()
    } else {
      serverLog.appendEvent("Removed the record of a server that is no longer running.")
    }
    removeRecord(.server, log: serverLog)
    return nil
  }

  /// Uses a found server: watches its PID and marks it running.
  func adopt(_ found: FoundServer, trigger: LocalServerStartTrigger) {
    let run = watch(
      kind: .server, ownership: found.ownership, identity: found.identity,
      commandLine: found.commandLine,
      onExit: { [weak self] run, exit in self?.serverExited(run, exit) })
    run.port = found.endpoint.port
    run.readyAt = dependencies.clock.now
    serverRun = run
    server = .running(found.endpoint, found.ownership)
    serverLog.appendEvent(
      "Using the server already running at \(found.endpoint.url.absoluteString) "
        + "(\(found.ownership.label.lowercased())).")
    onServerReady(found.endpoint, trigger)
  }

  /// Stops a host an earlier launch started: consent to host lasts one app session.
  func stopLeftoverHost() async {
    let record: LocalServerRecord?
    do {
      record = try dependencies.records.read(.host)
    } catch {
      note(error, in: hostLog)
      return
    }
    guard let record else { return }
    if dependencies.runner.identity(of: record.process.pid) == record.process {
      hostLog.appendEvent(
        "Stopping the host an earlier launch left running (PID \(record.process.pid)). "
          + "Start it again from the Server menu to keep hosting.")
      let run = watch(
        kind: .host, ownership: .recovered, identity: record.process,
        commandLine: record.commandLine, onExit: { _, _ in })
      if case .failure(let error) = await terminate(run, log: hostLog) {
        note(error, in: hostLog)
      }
      run.cancelTasks()
    }
    removeRecord(.host, log: hostLog)
  }
}
