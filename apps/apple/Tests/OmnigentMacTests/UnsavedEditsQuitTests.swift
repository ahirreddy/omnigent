import AppKit
import OmnigentViewTesting
import Testing

#if OMNIGENT_CHROMIUM
  import OmnigentDesktopUpdate
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// Quitting with unsaved edits: nothing is lost without the person's answer.
@MainActor
struct UnsavedEditsQuitTests {
  private final class Log {
    var discards = 0
    var saves = 0
    var failures: [[String]] = []
    var replies: [Bool] = []
    var proceeds = 0
  }

  private func quit(
    _ log: Log, answer: UnsavedEditsAlert.Choice, savesLeaving left: [String] = []
  ) -> UnsavedEditsQuit {
    UnsavedEditsQuit(
      ask: { _ in answer },
      saveAll: {
        await Task.yield()
        log.saves += 1
        return left
      },
      discardAll: { log.discards += 1 },
      showFailure: { log.failures.append($0) })
  }

  private func run(
    _ quit: UnsavedEditsQuit, _ log: Log, proceed: NSApplication.TerminateReply = .terminateNow,
    paths: [String] = ["/a"]
  ) -> NSApplication.TerminateReply {
    quit.run(
      paths: paths, reply: { log.replies.append($0) },
      proceed: {
        log.proceeds += 1
        return proceed
      })
  }

  private func waitForReply(_ log: Log) async throws {
    for _ in 0..<200 where log.replies.isEmpty && log.saves == 0 {
      try await Task.sleep(for: .milliseconds(5))
    }
    try await Task.sleep(for: .milliseconds(20))
  }

  @Test func noEditsQuitsWithoutAsking() {
    let log = Log()
    let reply = run(
      UnsavedEditsQuit(ask: { _ in
        Issue.record("asked with no edits")
        return .cancel
      }), log,
      paths: [])
    #expect(reply == .terminateNow)
    #expect(log.proceeds == 1)
  }

  @Test func cancelKeepsTheAppAndTheEdits() {
    let log = Log()
    #expect(run(quit(log, answer: .cancel), log) == .terminateCancel)
    #expect(log.discards == 0)
    #expect(log.proceeds == 0)
  }

  @Test func dontSaveDiscardsThenQuits() {
    let log = Log()
    #expect(run(quit(log, answer: .discard), log) == .terminateNow)
    #expect(log.discards == 1)
    #expect(log.proceeds == 1)
  }

  @Test func saveQuitsOnceEverythingIsSaved() async throws {
    let log = Log()
    #expect(run(quit(log, answer: .save), log) == .terminateLater)
    try await waitForReply(log)
    #expect(log.saves == 1)
    #expect(log.replies == [true])
    #expect(log.discards == 0)
  }

  @Test func aFailedSaveStaysOpenAndSaysWhich() async throws {
    let log = Log()
    #expect(run(quit(log, answer: .save, savesLeaving: ["/a"]), log) == .terminateLater)
    try await waitForReply(log)
    #expect(log.replies == [false])
    #expect(log.failures == [["/a"]])
    #expect(log.proceeds == 0)
  }

  @Test func aLaterQuitStepThatCancelsStaysOpen() async throws {
    let log = Log()
    _ = run(quit(log, answer: .save), log, proceed: .terminateCancel)
    try await waitForReply(log)
    #expect(log.replies == [false])
  }

  @Test func aLaterQuitStepThatRepliesItselfIsLeftToIt() async throws {
    let log = Log()
    _ = run(quit(log, answer: .save), log, proceed: .terminateLater)
    try await waitForReply(log)
    #expect(log.proceeds == 1)
    #expect(log.replies.isEmpty)
  }

  /// In the test host the delegate never asks, whatever is unsaved, and quitting saves state.
  @Test func theHostedDelegateQuitsWithoutAQuestion() {
    let delegate = OmnigentMacAppDelegate()
    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    #expect(delegate.services.isTerminating)
  }

  #if OMNIGENT_CHROMIUM
    @Test func updaterProblemsReachSettingsOnlyWhenItCouldNotStart() {
      struct Failure: Error {}
      let delegate = OmnigentMacAppDelegate()
      delegate.reportUpdater(.updateAborted(Failure()))
      #expect(delegate.services.updaterIssue == nil)
      delegate.reportUpdater(.startFailed(Failure()))
      #expect(delegate.services.updaterIssue?.hasPrefix("Automatic updates could not") == true)
      #expect(delegate.checkForUpdates != nil)
    }
  #else
    @Test func theAppStoreEditionHasNoUpdater() {
      #expect(OmnigentMacAppDelegate().checkForUpdates == nil)
    }
  #endif
}

/// The close prompt's answers. `SystemSideEffects` answers the sheet at once, so no window is
/// ever ordered in.
@MainActor
@Suite(.enabled(if: HostedOffscreen.isAllowed), .serialized)
struct UnsavedEditsPromptAnswerTests {
  private final class Calls {
    var saves = 0
    var discards = 0
  }

  private func window() -> NSWindow {
    SystemSideEffects.install()
    SystemSideEffects.reset()
    let window = NSWindow(
      contentRect: CGRect(x: -20_000, y: -20_000, width: 300, height: 200),
      styleMask: [.titled, .closable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
  }

  private func guardian(_ calls: Calls, leaving left: [String] = []) -> UnsavedEditsWindowGuard {
    UnsavedEditsWindowGuard(
      unsaved: { ["/work/a.rs"] },
      save: {
        await Task.yield()
        calls.saves += 1
        return left
      },
      discard: { calls.discards += 1 })
  }

  private func settle() async throws { try await Task.sleep(for: .milliseconds(30)) }

  @Test func cancelKeepsTheWindowAndTheEdits() async throws {
    let calls = Calls()
    let window = window()
    SystemSideEffects.answer(alert: .alertThirdButtonReturn)
    #expect(!guardian(calls).windowShouldClose(window))
    try await settle()
    #expect(SystemSideEffects.record.alertMessages.count == 1)
    #expect(calls.discards == 0)
    #expect(calls.saves == 0)
  }

  @Test func dontSaveDiscards() async throws {
    let calls = Calls()
    let window = window()
    SystemSideEffects.answer(alert: .alertSecondButtonReturn)
    #expect(!guardian(calls).windowShouldClose(window))
    try await settle()
    #expect(calls.discards == 1)
  }

  @Test func saveSaves() async throws {
    let calls = Calls()
    let window = window()
    SystemSideEffects.answer(alert: .alertFirstButtonReturn)
    let guardian = guardian(calls)
    #expect(!guardian.windowShouldClose(window))
    try await settle()
    #expect(calls.saves == 1)
    #expect(SystemSideEffects.record.alertMessages.count == 1)
  }

  @Test func aFailedSaveSaysWhichFiles() async throws {
    let calls = Calls()
    let window = window()
    SystemSideEffects.answer(alert: .alertFirstButtonReturn)
    let guardian = guardian(calls, leaving: ["/work/a.rs"])
    #expect(!guardian.windowShouldClose(window))
    try await settle()
    #expect(SystemSideEffects.record.alertMessages.last == "Some files could not be saved.")
  }

  @Test func aFailureWithNoWindowStillTells() async throws {
    _ = window()
    UnsavedEditsAlert.showFailure(["/work/a.rs"], in: nil)
    try await settle()
    #expect(SystemSideEffects.record.alertMessages == ["Some files could not be saved."])
  }
}
