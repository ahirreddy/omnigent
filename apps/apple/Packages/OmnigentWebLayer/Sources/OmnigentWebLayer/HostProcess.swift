internal import Darwin
internal import Foundation
internal import os

/// A spawned web host process. Reports its exit on the main actor.
final class HostProcess {
  let pid: pid_t
  /// Delivers a signal, returning `kill`'s result. A test swaps it to model a refusal.
  var sendSignal: (pid_t, Int32) -> Int32 = Darwin.kill
  private let process: Process
  private let exitSink: ExitSink

  /// Called once, on the main actor, with the exit status and whether a signal ended it.
  var onExit: ((Int32, Bool) -> Void)? {
    get { exitSink.handler }
    set { exitSink.handler = newValue }
  }

  init(executable: URL, arguments: [String]) throws(WebLayerError) {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let sink = ExitSink()
    process.terminationHandler = { finished in
      let status = finished.terminationStatus
      let signaled = finished.terminationReason == .uncaughtSignal
      DispatchQueue.main.async {
        MainActor.assumeIsolated { sink.fire(status: status, signaled: signaled) }
      }
    }
    do {
      try process.run()
    } catch {
      throw .launchFailed("\(executable.path): \(error.localizedDescription)")
    }
    self.process = process
    self.exitSink = sink
    self.pid = process.processIdentifier
  }

  var isRunning: Bool { process.isRunning }

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
    while process.isRunning, ContinuousClock.now < deadline {
      usleep(5_000)
    }
    return !process.isRunning
  }
}

private final class ExitSink {
  var handler: ((Int32, Bool) -> Void)?

  // The termination handler can drop the last reference on Process's queue; run deinit on the
  // main actor instead of trapping there.
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
