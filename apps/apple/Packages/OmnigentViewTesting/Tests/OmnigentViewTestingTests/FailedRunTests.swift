#if os(macOS)
  import AppKit
  import Testing

  @testable import OmnigentViewTesting

  /// What stops a run that can't be trusted. Each runs in a process of its own, because it ends it.
  @Suite("A test run that can't be trusted fails")
  struct FailedRunTests {
    @Test("a selector the SDK lacks fails the run and names it")
    func missingSelector() async throws {
      let result = await #expect(
        processExitsWith: .exitCode(70), observing: [\.standardErrorContent]
      ) {
        _ = unsafe SystemSideEffects.method(NSObject.self, "noSuchSelector")
      }
      let output = String(bytes: try #require(result).standardErrorContent, encoding: .utf8)
      #expect(output?.contains("has no noSuchSelector") == true)
    }

    @Test("a shield that didn't start fails the run, and one that did lets it go on")
    func missingShield() async {
      SystemSideEffects.requireShield(isRequested: true)
      await #expect(processExitsWith: .exitCode(70)) {
        SystemSideEffects.requireShield(isRequested: false)
      }
    }

    @Test("an exit from the runner's own loop fails the run and says why")
    func falsePassFailsTheRun() async throws {
      let result = await #expect(
        processExitsWith: .exitCode(70), observing: [\.standardErrorContent]
      ) {
        SystemSideEffects.endRunIfEarly(callStack: ["exit", "swift_task_asyncMainDrainQueue"])
      }
      let output = String(bytes: try #require(result).standardErrorContent, encoding: .utf8)
      #expect(output?.contains("FALSE PASS") == true)
    }
  }
#endif
