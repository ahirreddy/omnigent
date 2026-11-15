#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentViewTesting

  /// A button whose click shows a label, after a layout pass that changes the window's views.
  private struct Reveal: View {
    @State private var isShown = false

    var body: some View {
      VStack {
        Button("Show") { isShown = true }
        if isShown { Text("Shown").frame(width: 120, height: 40) }
      }
      .frame(width: 200, height: 200)
    }
  }

  @MainActor
  private final class Flag {
    var isSet = false
  }

  @MainActor
  @Suite("Waits that end at rest", .serialized)
  struct MainLoopTests {
    private func elapsed(_ body: () async throws -> Void) async rethrows -> TimeInterval {
      let start = CFAbsoluteTimeGetCurrent()
      try await body()
      return CFAbsoluteTimeGetCurrent() - start
    }

    @Test("a click's result is there when it returns, long before the settle's limit")
    func clickSettlesEarly() async throws {
      let screen = OffscreenWindow(Reveal(), width: 200, height: 200)
      defer { screen.close() }
      let seconds = try await elapsed {
        try screen.clickControl(at: 0)
        screen.settle(2)
      }
      #expect(screen.allViews.contains { $0.frame.size == CGSize(width: 120, height: 40) })
      #expect(seconds < 1, "\(seconds)")
    }

    @Test("a timer due after the limit is left for later")
    func leavesLaterTimers() async {
      let timer = Timer(timeInterval: 5, repeats: false) { _ in }
      RunLoop.main.add(timer, forMode: .common)
      defer { timer.invalidate() }
      let seconds = await elapsed { MainLoop.settle(limit: 0.5) }
      #expect(seconds < 0.4, "\(seconds)")
    }

    @Test("a repeating timer, such as a poll, is no work to wait for")
    func ignoresRepeatingTimers() async {
      let poll = Timer(timeInterval: 0.02, repeats: true) { _ in }
      RunLoop.main.add(poll, forMode: .common)
      defer { poll.invalidate() }
      let seconds = await elapsed { MainLoop.settle(limit: 0.5) }
      #expect(seconds < 0.4, "\(seconds)")
    }

    @Test("a task queued for the main actor runs before the async settle returns")
    func runsQueuedTasks() async {
      let done = Flag()
      Task { @MainActor in
        await Task.yield()
        await Task.yield()
        done.isSet = true
      }
      await MainLoop.settleTasks(limit: .seconds(1))
      #expect(done.isSet)
    }

    @Test("a task's sleep ending before the limit is waited for, and its work runs")
    func waitsForSleepingTask() async {
      let done = Flag()
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(80))
        done.isSet = true
      }
      await MainLoop.settleTasks(limit: .seconds(1))
      #expect(done.isSet)
    }

    @Test("with nothing to do the async settle ends at once")
    func idleSettleTasks() async {
      let seconds = await elapsed { await MainLoop.settleTasks(limit: .seconds(1)) }
      #expect(seconds < 0.5, "\(seconds)")
    }

    @Test("waiting for a condition ends when it holds, or fails after the timeout")
    func waitUntil() async {
      var count = 0
      let held = await MainLoop.waitUntil(timeout: .seconds(5)) {
        count += 1
        return count == 3
      }
      #expect(held)
      let seconds = await elapsed {
        #expect(!(await MainLoop.waitUntil(timeout: .milliseconds(50)) { false }))
      }
      #expect(seconds >= 0.05)
    }

    @Test("a sync condition wait sees a timer's change")
    func settleUntil() {
      let fired = Flag()
      let timer = Timer(timeInterval: 0.02, repeats: false) { _ in
        MainActor.assumeIsolated { fired.isSet = true }
      }
      RunLoop.main.add(timer, forMode: .common)
      #expect(MainLoop.settle(until: { fired.isSet }, timeout: 5))
    }

    @Test("the test process asks views and windows for no animation")
    func motionIsQuiet() {
      let defaults = UserDefaults.standard
      #expect(defaults.bool(forKey: TestRunnerSettings.animationsKey))
      #expect(defaults.double(forKey: "NSWindowResizeTime") < 0.01)
      #expect(!defaults.bool(forKey: "NSAutomaticWindowAnimationsEnabled"))
    }
  }
#endif
