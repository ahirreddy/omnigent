import Darwin
public import Foundation
import Synchronization

/// Runs local processes with `posix_spawn`.
///
/// `Foundation.Process` cannot set spawn attributes, so this calls `posix_spawn` directly:
///
/// - `POSIX_SPAWN_SETPGROUP` puts each child in its own process group. Stopping signals the
///   whole group, which reaches the Python server behind a `uv run` wrapper, and a Control-C in
///   the terminal that launched the app does not reach the child.
/// - `POSIX_SPAWN_CLOEXEC_DEFAULT` closes every descriptor except standard input (`/dev/null`)
///   and the two output pipes, so the child cannot hold the app's sockets or files open.
/// - `POSIX_SPAWN_SETSIGDEF` and `POSIX_SPAWN_SETSIGMASK` give the child default signal
///   handling and an empty mask whatever the app has blocked or ignored.
///
/// macOS has no parent-death signal, so a child outlives an app that crashes. The manager stops
/// what it started on a normal quit, and its record lets the next launch find a server that
/// survived a crash (see `LocalServerManager`).
nonisolated public struct PosixSpawnProcessRunner: LocalProcessRunning {
  /// Creates the runner.
  public init() {}

  /// Spawns a process in its own process group with both output pipes captured.
  /// - Parameter launch: What to run.
  /// - Returns: The running child.
  /// - Throws: `LocalServerError.spawnFailed` or `.spawnSetupFailed`.
  public func launch(_ launch: LocalProcessLaunch) throws(LocalServerError)
    -> any LocalProcessHandle
  {
    let stdout = try OutputPipe()
    let stderr: OutputPipe
    do {
      stderr = try OutputPipe()
    } catch {
      stdout.closeBoth()
      throw error
    }
    let pid: pid_t
    do {
      pid = try Self.spawn(launch, stdout: stdout.writeEnd, stderr: stderr.writeEnd)
    } catch {
      stdout.closeBoth()
      stderr.closeBoth()
      throw error
    }
    close(stdout.writeEnd)
    close(stderr.writeEnd)
    return SpawnedProcess(pid: pid, stdout: stdout.readEnd, stderr: stderr.readEnd)
  }

  /// The identity of a running process, or `nil` when no such process exists (or it is a
  /// zombie waiting to be reaped).
  /// - Parameter pid: The PID.
  /// - Returns: Its identity.
  public func identity(of pid: Int32) -> LocalProcessIdentity? {
    guard pid > 0 else { return nil }
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = unsafe kinfo_proc()
    var size = unsafe MemoryLayout<kinfo_proc>.stride
    let result = unsafe sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
    // A missing PID succeeds with size 0.
    guard result == 0, size > 0, unsafe info.kp_proc.p_stat != SZOMB else { return nil }
    let start = unsafe info.kp_proc.p_un.__p_starttime
    return LocalProcessIdentity(
      pid: pid, startMicroseconds: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec))
  }

  /// Returns once a process the app did not spawn exits, using a kqueue process source.
  /// - Parameter pid: The PID.
  public func waitForExit(ofUnrelated pid: Int32) async {
    let watch = UnrelatedExitWatch(pid: pid)
    await withTaskCancellationHandler {
      await watch.wait(isAlive: { identity(of: pid) != nil })
    } onCancel: {
      watch.finish()
    }
  }

  /// Signals the process group led by `pid`, or the process alone when it leads no group.
  /// `ESRCH` (already gone) is success.
  /// - Parameters:
  ///   - signal: The signal.
  ///   - pid: The PID.
  /// - Throws: `LocalServerError.commandFailed` when the kernel refuses.
  public func send(_ signal: LocalProcessSignal, toGroupOf pid: Int32) throws(LocalServerError) {
    if killpg(pid, signal.rawValue) == 0 { return }
    let groupError = errno
    if groupError == ESRCH, Darwin.kill(pid, signal.rawValue) == 0 || errno == ESRCH { return }
    throw .commandFailed(
      command: "kill -\(signal.rawValue) \(pid)", exit: nil, output: Errno.describe(groupError))
  }

  /// Whether `127.0.0.1:port` can be bound now, with `SO_REUSEADDR` as uvicorn binds.
  /// - Parameter port: The TCP port.
  /// - Returns: `true` when free.
  /// - Throws: `LocalServerError.spawnSetupFailed` when no socket could be created.
  public func isLoopbackPortAvailable(_ port: Int) throws(LocalServerError) -> Bool {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else { throw .spawnSetupFailed("socket: \(Errno.describe(errno))") }
    defer { close(socketFD) }
    var reuse: Int32 = 1
    let length = socklen_t(MemoryLayout<Int32>.size)
    guard unsafe setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, length) == 0 else {
      throw .spawnSetupFailed("setsockopt: \(Errno.describe(errno))")
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(clamping: port).bigEndian)
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    let bound = withUnsafePointer(to: &address) { pointer in
      unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
        unsafe bind(socketFD, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return bound == 0
  }

  private static func spawn(_ launch: LocalProcessLaunch, stdout: Int32, stderr: Int32)
    throws(LocalServerError) -> pid_t
  {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard unsafe posix_spawn_file_actions_init(&actions) == 0 else {
      throw .spawnSetupFailed("posix_spawn_file_actions_init: \(Errno.describe(errno))")
    }
    defer { unsafe posix_spawn_file_actions_destroy(&actions) }
    guard unsafe posix_spawnattr_init(&attributes) == 0 else {
      throw .spawnSetupFailed("posix_spawnattr_init: \(Errno.describe(errno))")
    }
    defer { unsafe posix_spawnattr_destroy(&attributes) }

    var steps: [(String, Int32)] = [
      (
        "open /dev/null",
        unsafe posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
      ),
      ("dup2 stdout", unsafe posix_spawn_file_actions_adddup2(&actions, stdout, 1)),
      ("dup2 stderr", unsafe posix_spawn_file_actions_adddup2(&actions, stderr, 2)),
    ]
    if let directory = launch.workingDirectory {
      steps.append(("chdir", unsafe posix_spawn_file_actions_addchdir(&actions, directory.path)))
    }
    let flags =
      POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
      | POSIX_SPAWN_CLOEXEC_DEFAULT
    var emptyMask = sigset_t()
    var allSignals = sigset_t()
    unsafe sigemptyset(&emptyMask)
    unsafe sigfillset(&allSignals)
    steps += [
      ("setflags", unsafe posix_spawnattr_setflags(&attributes, Int16(flags))),
      ("setpgroup", unsafe posix_spawnattr_setpgroup(&attributes, 0)),
      ("setsigmask", unsafe posix_spawnattr_setsigmask(&attributes, &emptyMask)),
      ("setsigdefault", unsafe posix_spawnattr_setsigdefault(&attributes, &allSignals)),
    ]
    if let failed = steps.first(where: { $0.1 != 0 }) {
      throw .spawnSetupFailed("\(failed.0): \(Errno.describe(failed.1))")
    }

    let argv = [launch.executable.path] + launch.arguments
    let envp = launch.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    var pid: pid_t = 0
    let status = unsafe CStringArray.with(argv) { argvPointer in
      unsafe CStringArray.with(envp) { envPointer in
        unsafe posix_spawn(
          &pid, launch.executable.path, &actions, &attributes, argvPointer, envPointer)
      }
    }
    guard status == 0 else {
      throw .spawnFailed(executable: launch.executable.path, errno: status)
    }
    return pid
  }
}

/// `strerror` text for an errno value.
nonisolated enum Errno {
  static func describe(_ code: Int32) -> String {
    "\(unsafe String(cString: strerror(code))) (errno \(code))"
  }
}

/// A NULL-terminated `char *[]` that lives for the duration of a closure.
nonisolated enum CStringArray {
  static func with<Result>(
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
}

/// A pipe whose ends are close-on-exec in the parent, so unrelated spawns never inherit them.
nonisolated struct OutputPipe {
  let readEnd: Int32
  let writeEnd: Int32

  init() throws(LocalServerError) {
    var fds: [Int32] = [-1, -1]
    guard unsafe pipe(&fds) == 0 else { throw .spawnSetupFailed("pipe: \(Errno.describe(errno))") }
    readEnd = fds[0]
    writeEnd = fds[1]
    for descriptor in fds where fcntl(descriptor, F_SETFD, FD_CLOEXEC) != 0 {
      let code = errno
      closeBoth()
      throw .spawnSetupFailed("fcntl FD_CLOEXEC: \(Errno.describe(code))")
    }
  }

  func closeBoth() {
    close(readEnd)
    close(writeEnd)
  }
}

/// A child spawned by `PosixSpawnProcessRunner`. One thread reaps it with `waitpid`, and one
/// thread per pipe reads its output, because blocking reads are the simplest correct way to see
/// every byte up to EOF.
nonisolated final class SpawnedProcess: LocalProcessHandle {
  private enum ExitState {
    case running(waiters: [CheckedContinuation<LocalProcessExit, Never>])
    case exited(LocalProcessExit)
  }

  let pid: Int32
  let output: AsyncStream<LocalProcessOutput>
  private let state = Mutex(ExitState.running(waiters: []))

  init(pid: Int32, stdout: Int32, stderr: Int32) {
    self.pid = pid
    let (stream, continuation) = AsyncStream.makeStream(of: LocalProcessOutput.self)
    output = stream
    let openPipes = Mutex(2)
    let pipes = [(stdout, LocalProcessOutput.Stream.standardOutput), (stderr, .standardError)]
    for (descriptor, kind) in pipes {
      Thread.detachNewThread {
        Self.drain(descriptor, kind, into: continuation)
        let remaining = openPipes.withLock { count in
          count -= 1
          return count
        }
        if remaining == 0 { continuation.finish() }
      }
    }
    Thread.detachNewThread { [self] in
      let exit = Self.reap(pid)
      let waiters = state.withLock { current -> [CheckedContinuation<LocalProcessExit, Never>] in
        guard case .running(let waiters) = current else { return [] }
        current = .exited(exit)
        return waiters
      }
      for waiter in waiters { waiter.resume(returning: exit) }
    }
  }

  func waitForExit() async -> LocalProcessExit {
    await withCheckedContinuation { continuation in
      let finished = state.withLock { current -> LocalProcessExit? in
        switch current {
        case .exited(let exit): return exit
        case .running(var waiters):
          waiters.append(continuation)
          current = .running(waiters: waiters)
          return nil
        }
      }
      if let finished { continuation.resume(returning: finished) }
    }
  }

  func send(_ signal: LocalProcessSignal) throws(LocalServerError) {
    // Held across `killpg` so the reaper cannot mark the exit (freeing the PID) mid-signal.
    let failure = state.withLock { current -> Int32? in
      guard case .running = current else { return nil }
      return killpg(pid, signal.rawValue) == 0 || errno == ESRCH ? nil : errno
    }
    if let failure {
      throw .commandFailed(
        command: "kill -\(signal.rawValue) -\(pid)", exit: nil, output: Errno.describe(failure))
    }
  }

  private static func drain(
    _ descriptor: Int32, _ kind: LocalProcessOutput.Stream,
    into continuation: AsyncStream<LocalProcessOutput>.Continuation
  ) {
    defer { close(descriptor) }
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        unsafe read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count > 0 {
        continuation.yield(LocalProcessOutput(kind, Data(buffer[0..<count])))
      } else if count == 0 {
        return
      } else if errno != EINTR {
        let message = "[Omnigent] Reading the process output failed: \(Errno.describe(errno))\n"
        continuation.yield(LocalProcessOutput(kind, Data(message.utf8)))
        return
      }
    }
  }

  private static func reap(_ pid: Int32) -> LocalProcessExit {
    var status: Int32 = 0
    while true {
      let result = unsafe waitpid(pid, &status, 0)
      if result == pid { break }
      // ECHILD means something else reaped it; nothing more can be learned.
      if result == -1, errno != EINTR { return .unknown }
    }
    // The <sys/wait.h> macros are not imported: low 7 bits are the signal, 0 for a normal exit.
    let signal = status & 0x7f
    return signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
  }
}

/// Waits for a process the app did not spawn to exit, using `DispatchSource.makeProcessSource`.
nonisolated final class UnrelatedExitWatch: Sendable {
  private struct State {
    var continuation: CheckedContinuation<Void, Never>?
    var source: (any DispatchSourceProcess)?
    var finished = false
  }

  private let pid: Int32
  private let state = Mutex(State())

  init(pid: Int32) {
    self.pid = pid
  }

  func wait(isAlive: @escaping @Sendable () -> Bool) async {
    await withCheckedContinuation { continuation in
      let source = DispatchSource.makeProcessSource(
        identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
      let alreadyFinished = state.withLock { current -> Bool in
        if current.finished { return true }
        current.continuation = continuation
        current.source = source
        return false
      }
      if alreadyFinished {
        continuation.resume()
        return
      }
      source.setEventHandler { [self] in finish() }
      source.resume()
      // kqueue cannot watch a process that already exited, so check after arming.
      if !isAlive() { finish() }
    }
  }

  func finish() {
    let (continuation, source) = state.withLock { current in
      current.finished = true
      defer {
        current.continuation = nil
        current.source = nil
      }
      return (current.continuation, current.source)
    }
    source?.cancel()
    continuation?.resume()
  }
}
