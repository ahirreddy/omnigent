import Foundation
import Synchronization

@testable import OmnigentDesktop

/// A scripted child process.
final class FakeProcess: LocalProcessHandle {
  private struct State {
    var exit: LocalProcessExit?
    var waiters: [CheckedContinuation<LocalProcessExit, Never>] = []
    var signals: [LocalProcessSignal] = []
  }

  let pid: Int32
  let output: AsyncStream<LocalProcessOutput>
  let launch: LocalProcessLaunch
  /// Exit on SIGINT or SIGTERM. Off simulates a process that ignores them.
  let exitsOnTerminate: Bool
  private let continuation: AsyncStream<LocalProcessOutput>.Continuation
  private let state = Mutex(State())

  init(pid: Int32, launch: LocalProcessLaunch, exitsOnTerminate: Bool) {
    self.pid = pid
    self.launch = launch
    self.exitsOnTerminate = exitsOnTerminate
    (output, continuation) = AsyncStream.makeStream(of: LocalProcessOutput.self)
  }

  var signals: [LocalProcessSignal] { state.withLock { $0.signals } }
  var hasExited: Bool { state.withLock { $0.exit != nil } }

  func print(_ line: String, stream: LocalProcessOutput.Stream = .standardOutput) {
    continuation.yield(LocalProcessOutput(stream, Data((line + "\n").utf8)))
  }

  func exit(_ exit: LocalProcessExit) {
    continuation.finish()
    let waiters = state.withLock { current -> [CheckedContinuation<LocalProcessExit, Never>] in
      guard current.exit == nil else { return [] }
      current.exit = exit
      defer { current.waiters = [] }
      return current.waiters
    }
    for waiter in waiters { waiter.resume(returning: exit) }
  }

  func waitForExit() async -> LocalProcessExit {
    await withCheckedContinuation { continuation in
      let done = state.withLock { current -> LocalProcessExit? in
        if let exit = current.exit { return exit }
        current.waiters.append(continuation)
        return nil
      }
      if let done { continuation.resume(returning: done) }
    }
  }

  func send(_ signal: LocalProcessSignal) throws(LocalServerError) {
    let running = state.withLock { current -> Bool in
      guard current.exit == nil else { return false }
      current.signals.append(signal)
      return true
    }
    guard running else { return }
    if signal == .kill || exitsOnTerminate { exit(.signaled(signal.rawValue)) }
  }
}

/// Scripts processes: each launch runs the next behavior, or the default one.
final class FakeRunner: LocalProcessRunning {
  typealias Behavior = @Sendable (FakeProcess) -> Void

  private struct State {
    var nextPID: Int32 = 1_000
    var processes: [FakeProcess] = []
    var behaviors: [Behavior] = []
    var external: [Int32: LocalProcessIdentity] = [:]
    var externalSignals: [(Int32, LocalProcessSignal)] = []
    var externalWaiters: [Int32: [CheckedContinuation<Void, Never>]] = [:]
    var busyPorts: Set<Int> = []
    var ignoresTerminate = false
  }

  private let state = Mutex(State())

  var processes: [FakeProcess] { state.withLock { $0.processes } }
  var launches: [LocalProcessLaunch] { processes.map(\.launch) }
  var externalSignals: [(Int32, LocalProcessSignal)] { state.withLock { $0.externalSignals } }

  /// Queues behaviors for the next launches, in order.
  func script(_ behaviors: Behavior...) {
    state.withLock { current in current.behaviors += behaviors }
  }

  func ignoreTerminate() {
    state.withLock { $0.ignoresTerminate = true }
  }

  func setBusy(_ port: Int) {
    state.withLock { current in
      current.busyPorts.insert(port)
      return
    }
  }

  /// A live process the app did not spawn.
  func addExternal(_ identity: LocalProcessIdentity) {
    state.withLock { $0.external[identity.pid] = identity }
  }

  func endExternal(_ pid: Int32) {
    let waiters = state.withLock { current -> [CheckedContinuation<Void, Never>] in
      current.external[pid] = nil
      defer { current.externalWaiters[pid] = nil }
      return current.externalWaiters[pid] ?? []
    }
    for waiter in waiters { waiter.resume() }
  }

  func launch(_ launch: LocalProcessLaunch) throws(LocalServerError) -> any LocalProcessHandle {
    let (process, behavior) = state.withLock { current -> (FakeProcess, Behavior?) in
      current.nextPID += 1
      let process = FakeProcess(
        pid: current.nextPID, launch: launch, exitsOnTerminate: !current.ignoresTerminate)
      current.processes.append(process)
      let behavior = current.behaviors.isEmpty ? nil : current.behaviors.removeFirst()
      return (process, behavior)
    }
    behavior?(process)
    return process
  }

  func identity(of pid: Int32) -> LocalProcessIdentity? {
    state.withLock { current in
      if let external = current.external[pid] { return external }
      guard let process = current.processes.first(where: { $0.pid == pid }), !process.hasExited
      else { return nil }
      return LocalProcessIdentity(pid: pid, startMicroseconds: Int64(pid) * 1_000)
    }
  }

  func waitForExit(ofUnrelated pid: Int32) async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let gone = state.withLock { current -> Bool in
          guard current.external[pid] != nil else { return true }
          current.externalWaiters[pid, default: []].append(continuation)
          return false
        }
        if gone { continuation.resume() }
      }
    } onCancel: {
      endWaiters(pid)
    }
  }

  private func endWaiters(_ pid: Int32) {
    let waiters = state.withLock { current in
      defer { current.externalWaiters[pid] = nil }
      return current.externalWaiters[pid] ?? []
    }
    for waiter in waiters { waiter.resume() }
  }

  func send(_ signal: LocalProcessSignal, toGroupOf pid: Int32) throws(LocalServerError) {
    let ends = state.withLock { current -> Bool in
      current.externalSignals.append((pid, signal))
      return signal == .kill || !current.ignoresTerminate
    }
    if ends { endExternal(pid) }
  }

  func isLoopbackPortAvailable(_ port: Int) throws(LocalServerError) -> Bool {
    state.withLock { !$0.busyPorts.contains(port) }
  }
}

/// Answers probes from a per-URL script; the last answer repeats.
final class FakeProbe: LocalServerProbing {
  private let answers = Mutex([URL: [LocalServerProbeResult]]())
  private let counts = Mutex([URL: Int]())

  func answer(_ url: URL, _ results: LocalServerProbeResult...) {
    answers.withLock { $0[url] = results }
  }

  func count(_ url: URL) -> Int { counts.withLock { $0[url] ?? 0 } }

  /// What `signInProbe` answers, and the bearers it was asked with.
  private let signIn = Mutex((answer: CLISignInProbe.unreachable, bearers: [String?]()))

  func answerSignIn(_ answer: CLISignInProbe) { signIn.withLock { $0.answer = answer } }

  var signInBearers: [String?] { signIn.withLock(\.bearers) }

  func signInProbe(_ serverURL: URL, bearer: String?) async -> CLISignInProbe {
    await Task.yield()  // A real probe suspends on the network.
    return signIn.withLock { state in
      state.bearers.append(bearer)
      return state.answer
    }
  }

  func probe(_ baseURL: URL) async -> LocalServerProbeResult {
    await Task.yield()  // A real probe suspends on the network.
    counts.withLock { $0[baseURL, default: 0] += 1 }
    return answers.withLock { current in
      guard var results = current[baseURL], !results.isEmpty else {
        return .notReady("connection refused")
      }
      let next = results.count > 1 ? results.removeFirst() : results[0]
      current[baseURL] = results
      return next
    }
  }
}

/// Time that passes only when slept, and records each sleep.
final class FakeClock: LocalServerClock {
  private let base = ContinuousClock.now
  private let elapsed = Mutex(Duration.zero)
  private let sleeps = Mutex([Duration]())

  var now: ContinuousClock.Instant { base + elapsed.withLock { $0 } }
  var recordedSleeps: [Duration] { sleeps.withLock { $0 } }

  func sleep(for duration: Duration) async throws {
    try Task.checkCancellation()
    sleeps.withLock { $0.append(duration) }
    elapsed.withLock { $0 += duration }
    // Let output and exit tasks run between polls, as real sleeps would.
    for _ in 0..<5 { await Task.yield() }
    try Task.checkCancellation()
  }
}

/// A manager wired to fakes in a private temporary directory.
@MainActor
struct LocalServerHarness {
  let runner = FakeRunner()
  let probe = FakeProbe()
  let clock = FakeClock()
  let root: URL
  let preferences: LocalServerPreferences
  let manager: LocalServerManager
  let records: LocalServerRecordStore

  nonisolated static let cliPath = "/fake/bin/omnigent"

  init(
    capability: LocalServerCapability = .available,
    executables: Set<String> = [Self.cliPath],
    configure: (LocalServerPreferences) -> Void = { _ in }
  ) throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "lsm-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "ai.omnigent.desktop.lsm.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
      throw FixtureError(description: "no defaults suite")
    }
    preferences = LocalServerPreferences(defaults: defaults)
    preferences.dataDirectory = root.appending(path: "data").path
    configure(preferences)
    records = LocalServerRecordStore(directory: root.appending(path: "records"))
    let system = LocalCLIDiscovery.System(
      homeDirectory: root, isExecutableFile: { executables.contains($0) },
      loginShellPath: { "/fake/bin:/usr/bin:/bin" })
    var timing = LocalServerManager.Timing()
    timing.serverReadiness = .seconds(30)
    timing.hostConnect = .seconds(30)
    let dependencies = LocalServerManager.Dependencies(
      runner: runner, probe: probe, clock: clock, records: records, cliSystem: system,
      environment: ["HOME": root.path, "DYLD_INSERT_LIBRARIES": "/x.dylib", "LANG": "C"],
      homeDirectory: root, timing: timing)
    manager = LocalServerManager(
      capability: capability, preferences: preferences, dependencies: dependencies)
  }

  var dataDirectory: URL { root.appending(path: "data") }

  /// Writes the CLI's canonical pidfile.
  func writeCanonicalRecord(pid: Int32, port: Int) throws {
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    try "\(pid)\n\(port)\n".write(
      to: CanonicalServerRecord.fileURL(dataDirectory: dataDirectory), atomically: true,
      encoding: .utf8)
  }

  func cleanUp() {
    do {
      try FileManager.default.removeItem(at: root)
    } catch {
      Swift.print("could not remove \(root.path): \(error)")
    }
  }
}

/// A server process that announces `port` and keeps running.
func announces(_ port: Int) -> FakeRunner.Behavior {
  { process in process.print("Starting omnigent server on 127.0.0.1:\(port)") }
}

func loopback(_ port: Int) throws -> URL {
  guard let url = LocalServerEndpoint.loopbackURL(port: port) else {
    throw FixtureError(description: "bad port \(port)")
  }
  return url
}

/// Polls `condition` in real time, for short bounded waits on work already in flight.
@MainActor
func waitUntil(within duration: Duration, _ condition: () -> Bool) async {
  let deadline = ContinuousClock.now + duration
  while !condition(), ContinuousClock.now < deadline {
    do {
      try await Task.sleep(for: .milliseconds(10))
    } catch {
      return
    }
  }
}
