import Foundation

/// The result of a short command run to completion.
nonisolated public struct LocalCommandResult: Equatable, Sendable {
  /// How it ended.
  public var exit: LocalProcessExit
  /// Standard output, decoded as UTF-8 with invalid bytes replaced.
  public var standardOutput: String
  /// Standard error, decoded the same way.
  public var standardError: String

  /// Both streams for messages, trimmed.
  public var combinedOutput: String {
    [standardOutput, standardError]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }
}

/// Runs short commands (`$SHELL -l -c ...`, `omnigent server stop`) to completion with a
/// timeout. Long-lived processes go through `LocalServerManager` instead.
nonisolated enum LocalCommand {
  /// Runs `launch` and collects its output.
  /// - Parameters:
  ///   - launch: What to run.
  ///   - runner: Spawns it.
  ///   - clock: Measures the timeout.
  ///   - timeout: How long before the process group is killed.
  ///   - drainLimit: How long to keep reading output after the exit.
  /// - Returns: The exit and output.
  /// - Throws: `LocalServerError.spawnFailed`, or `.commandFailed` on timeout.
  static func run(
    _ launch: LocalProcessLaunch, runner: any LocalProcessRunning,
    clock: any LocalServerClock, timeout: Duration, drainLimit: Duration = .seconds(2)
  ) async throws(LocalServerError) -> LocalCommandResult {
    let process = try runner.launch(launch)
    let collector = Task {
      var stdout = Data()
      var stderr = Data()
      for await chunk in process.output {
        switch chunk.stream {
        case .standardOutput: stdout.append(chunk.data)
        case .standardError: stderr.append(chunk.data)
        }
      }
      return (stdout, stderr)
    }
    let watchdog = Task { () -> String? in
      do {
        try await clock.sleep(for: timeout)
      } catch {
        return nil  // Cancelled: the command finished first.
      }
      do throws(LocalServerError) {
        try process.send(.kill)
        return "timed out after \(timeout.components.seconds) seconds and was killed"
      } catch {
        return "timed out after \(timeout.components.seconds) seconds; killing it failed: "
          + error.message
      }
    }
    let exit = await process.waitForExit()
    watchdog.cancel()
    let timeoutProblem = await watchdog.value
    // A grandchild (a shell's background helper, say) can hold the pipes open after the command
    // exits. Stop reading shortly after the exit instead of waiting for an EOF that may not come.
    // Real time on purpose: this only bounds a hang, and test clocks do not really sleep.
    let drainTimer = Task {
      do {
        try await Task.sleep(for: drainLimit)
        collector.cancel()
      } catch {
        // Cancelled: the output finished first.
      }
    }
    let (stdout, stderr) = await collector.value
    drainTimer.cancel()
    let result = LocalCommandResult(
      exit: exit, standardOutput: stdout.lossyUTF8, standardError: stderr.lossyUTF8)
    if let timeoutProblem {
      throw .commandFailed(command: launch.commandLine, exit: exit, output: timeoutProblem)
    }
    return result
  }
}
