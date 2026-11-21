internal import Darwin
internal import Foundation
internal import Synchronization
internal import os

/// A spawned web host process. Reports its exit on the main actor.
///
/// Spawned with `posix_spawn` (as `PosixSpawnProcessRunner` in OmnigentDesktop does) so the host
/// can get extra descriptors, the DevTools pipe, while every other descriptor of the app stays
/// closed in it.
final class HostProcess {
  let pid: pid_t
  /// Delivers a signal, returning `kill`'s result. A test swaps it to model a refusal.
  var sendSignal: (pid_t, Int32) -> Int32 = Darwin.kill
  private let exitSink: ExitSink
  private let exited = ExitFlag()

  /// Called once, on the main actor, with the exit status and whether a signal ended it.
  var onExit: ((Int32, Bool) -> Void)? {
    get { exitSink.handler }
    set { exitSink.handler = newValue }
  }

  /// Spawns `executable` with standard input from `/dev/null` and the app's standard output.
  /// - Parameters:
  ///   - executable: The program.
  ///   - arguments: Its arguments, without the program name.
  ///   - descriptors: Extra descriptors for the child, keyed by their number there (for example
  ///     `[3: commandsReadEnd, 4: repliesWriteEnd]`). The caller still owns and closes its own.
  /// - Throws: `.launchFailed` when the process cannot start.
  init(executable: URL, arguments: [String], descriptors: [Int32: Int32] = [:])
    throws(WebLayerError)
  {
    let pid = try Self.spawn(executable: executable, arguments: arguments, descriptors: descriptors)
    let sink = ExitSink()
    self.pid = pid
    exitSink = sink
    let exited = exited
    Thread.detachNewThread {
      let (status, signaled) = reapChild(pid)
      exited.value.withLock { $0 = true }
      DispatchQueue.main.async {
        MainActor.assumeIsolated { sink.fire(status: status, signaled: signaled) }
      }
    }
  }

  var isRunning: Bool { !exited.value.withLock { $0 } }

  /// Sends SIGKILL. A host that already exited is not an error.
  func kill() {
    if sendSignal(pid, SIGKILL) != 0, errno != ESRCH {
      Logger.session.error("kill(\(self.pid), SIGKILL) failed: errno \(errno)")
    }
  }

  /// Blocks the caller until the process exits or `timeout` passes.
  /// - Returns: Whether the process exited.
  func waitForExit(timeout: Duration) -> Bool {
    let deadline = ContinuousClock.now + timeout
    while isRunning, ContinuousClock.now < deadline {
      usleep(5_000)
    }
    return !isRunning
  }

  private static func spawn(executable: URL, arguments: [String], descriptors: [Int32: Int32])
    throws(WebLayerError) -> pid_t
  {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    let initActions = unsafe posix_spawn_file_actions_init(&actions)
    try check(executable, "posix_spawn_file_actions_init", initActions)
    defer { unsafe posix_spawn_file_actions_destroy(&actions) }
    try check(executable, "posix_spawnattr_init", unsafe posix_spawnattr_init(&attributes))
    defer { unsafe posix_spawnattr_destroy(&attributes) }

    var steps: [(String, Int32)] = [
      (
        "open /dev/null",
        unsafe posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
      ),
      ("inherit stdout", unsafe posix_spawn_file_actions_addinherit_np(&actions, 1)),
      ("inherit stderr", unsafe posix_spawn_file_actions_addinherit_np(&actions, 2)),
    ]
    for (child, parent) in descriptors.sorted(by: { $0.key < $1.key }) {
      let status =
        parent == child
        ? unsafe posix_spawn_file_actions_addinherit_np(&actions, parent)
        : unsafe posix_spawn_file_actions_adddup2(&actions, parent, child)
      steps.append(("descriptor \(child)", status))
    }
    // Only the descriptors named above reach the child; signals start at their defaults.
    let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
    var emptyMask = sigset_t()
    var allSignals = sigset_t()
    unsafe sigemptyset(&emptyMask)
    unsafe sigfillset(&allSignals)
    steps += [
      ("setflags", unsafe posix_spawnattr_setflags(&attributes, Int16(flags))),
      ("setsigmask", unsafe posix_spawnattr_setsigmask(&attributes, &emptyMask)),
      ("setsigdefault", unsafe posix_spawnattr_setsigdefault(&attributes, &allSignals)),
    ]
    for (step, status) in steps { try check(executable, step, status) }

    let argv = [executable.path] + arguments
    let environment = ProcessInfo.processInfo.environment.sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
    var pid: pid_t = 0
    let status = unsafe withCStringArray(argv) { argvPointer in
      unsafe withCStringArray(environment) { environmentPointer in
        unsafe posix_spawn(
          &pid, executable.path, &actions, &attributes, argvPointer, environmentPointer)
      }
    }
    try check(executable, "posix_spawn", status)
    return pid
  }

  /// Fails a spawn step, which returns its error code rather than setting `errno`.
  private static func check(_ executable: URL, _ step: String, _ status: Int32)
    throws(WebLayerError)
  {
    guard status == 0 else {
      let reason = unsafe String(cString: strerror(status))
      throw .launchFailed("\(executable.path): \(step): \(reason)")
    }
  }
}

/// Blocks until `pid` exits. Returns the exit status, or the signal and `true`.
nonisolated private func reapChild(_ pid: pid_t) -> (Int32, Bool) {
  var status: Int32 = 0
  while true {
    let result = unsafe waitpid(pid, &status, 0)
    if result == pid { break }
    // ECHILD means something else reaped it; report a plain exit.
    if result == -1, errno != EINTR { return (0, false) }
  }
  // The <sys/wait.h> macros are not imported: low 7 bits are the signal, 0 for a normal exit.
  let signal = status & 0x7f
  return signal == 0 ? ((status >> 8) & 0xff, false) : (signal, true)
}

/// A NULL-terminated `char *[]` that lives for the duration of `body`.
nonisolated private func withCStringArray<Result>(
  _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
  let pointers: [UnsafeMutablePointer<CChar>?] = unsafe strings.map { unsafe strdup($0) } + [nil]
  defer {
    for unsafe pointer in unsafe pointers { unsafe free(pointer) }
  }
  return pointers.withUnsafeBufferPointer { buffer in
    // `withUnsafeBufferPointer` on a non-empty array always has a base address.
    guard let base = buffer.baseAddress else { preconditionFailure("empty C array") }
    return unsafe body(base)
  }
}

/// Whether the reaper saw the child exit.
nonisolated private final class ExitFlag: Sendable {
  let value = Mutex(false)
}

private final class ExitSink {
  var handler: ((Int32, Bool) -> Void)?

  // The reaper thread can drop the last reference off the main actor; run deinit on the main
  // actor instead of trapping there.
  isolated deinit {}

  func fire(status: Int32, signaled: Bool) {
    let handler = handler
    self.handler = nil
    handler?(status, signaled)
  }
}

extension Logger {
  static let session = Logger(subsystem: "ai.omnigent.weblayer", category: "session")
  static let view = Logger(subsystem: "ai.omnigent.weblayer", category: "view")
}
