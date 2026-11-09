#if os(macOS)
  import Foundation

  /// Keeps the test runner's own run loop from being stopped.
  ///
  /// Every event from the window server queues a stop for the main run loop. When a test has
  /// suspended, that loop is the runner's, and its return ends the process part way through the
  /// run. So a run loop nested inside it takes the stops and starts again. Main actor jobs still
  /// run there, because it isn't inside a main queue job the way a test body is.
  enum RunnerLoopShield {
    /// Takes over the runner's loop the next time no test is running on it.
    static func install() {
      let timer = CFRunLoopTimerCreateWithHandler(
        nil, CFAbsoluteTimeGetCurrent(), 0, 0, 0
      ) { _ in
        guard isDirectlyOnRunnerLoop(callStack: Thread.callStackSymbols) else {
          // A run loop inside a test body: taking it over would never return to the test.
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { install() }
          return
        }
        runUntilProcessExits()
      }
      CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
    }

    /// Whether a call stack is under the loop Swift runs while an async `main` is suspended, with
    /// no main queue job between. A task's stack ends at its own async frames, so it has no loop.
    /// - Parameter callStack: The symbols of the call stack.
    /// - Returns: Whether that loop is running directly. XCTest has no such loop, nor the problem.
    static func isDirectlyOnRunnerLoop(callStack: [String]) -> Bool {
      let inMainQueueJob = callStack.contains { $0.contains("SERVICING_THE_MAIN_DISPATCH_QUEUE") }
      let onRunnerLoop = callStack.contains { $0.contains("swift_task_asyncMainDrainQueue") }
      return onRunnerLoop && !inMainQueueJob
    }

    /// A stop ends only this nested run. The runner leaves by calling `exit`.
    private static func runUntilProcessExits() {
      while CFRunLoopRunInMode(.defaultMode, .greatestFiniteMagnitude, false) != .finished {}
    }
  }
#endif
