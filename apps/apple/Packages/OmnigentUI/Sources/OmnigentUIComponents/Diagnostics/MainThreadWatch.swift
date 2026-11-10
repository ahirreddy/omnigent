public import Foundation
private import os

/// The main thread's run loop, for work that must wait until that thread is back at it.
nonisolated enum MainRunLoop {
  /// Runs `block` once the main thread is next back at its run loop, in any common mode. A
  /// block on the run loop, not the main queue: a modal loop inside a main-queue job never
  /// drains that queue.
  static func perform(_ block: @escaping @Sendable () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, block)
    CFRunLoopWakeUp(CFRunLoopGetMain())
  }

  /// Runs `block` on the main thread `seconds` from now, in any common mode: a run loop timer,
  /// for the same reason.
  static func perform(after seconds: TimeInterval, _ block: @escaping @Sendable () -> Void) {
    let fires = CFAbsoluteTimeGetCurrent() + seconds
    let timer = CFRunLoopTimerCreateWithHandler(nil, fires, 0, 0, 0) { _ in block() }
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
  }

  /// After Core Animation's own observer, which lays out and commits a frame at 2 000 000.
  static let afterDisplayOrder: CFIndex = 2_500_000

  /// Runs `block` back at the run loop once the main thread has laid out and committed its
  /// next frame, which it does before the loop waits or exits.
  static func performAfterDisplay(_ block: @escaping @Sendable () -> Void) {
    let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
    let observer = CFRunLoopObserverCreateWithHandler(
      nil, activities, false, afterDisplayOrder
    ) { _, _ in
      perform(block)
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    CFRunLoopWakeUp(CFRunLoopGetMain())
  }
}

/// Which lines a stall of the main thread is worth: one once it has lasted ``threshold``,
/// one each time it has lasted twice as long again, and one when it ends.
nonisolated struct StallReports {
  /// Lines while one stall lasts, so one that never ends is not logged for ever.
  static let reportsPerStall = 5
  /// Stalls reported per run.
  static let stallsReported = 100

  /// How long the main thread stays away from its run loop before it counts as a stall.
  let threshold: TimeInterval
  private var stalls = 0
  /// The silence the next line waits for, while a reported stall lasts.
  private var nextReport: TimeInterval?
  private var reports = 0
  private var longest: TimeInterval = 0

  init(threshold: TimeInterval) {
    self.threshold = threshold
  }

  /// The line to log now, if any.
  /// - Parameters:
  ///   - silent: How long ago the main thread last answered.
  ///   - busiest: What changed since it did, read only for a line.
  /// - Returns: The line, or `nil` when there is nothing to say.
  mutating func check(silentFor silent: TimeInterval, busiest: () -> String) -> String? {
    guard silent >= threshold else {
      guard nextReport != nil else { return nil }
      nextReport = nil
      return "STALL ended: the main thread was busy for \(Self.seconds(longest))"
    }
    if nextReport == nil {
      guard stalls < Self.stallsReported else { return nil }
      stalls += 1
      reports = 0
      nextReport = threshold
    }
    longest = silent
    guard let due = nextReport, silent >= due, reports < Self.reportsPerStall else { return nil }
    reports += 1
    nextReport = due * 2
    return "STALL main thread busy for \(Self.seconds(silent)); changed meanwhile: \(busiest())"
  }

  private static func seconds(_ interval: TimeInterval) -> String {
    "\((interval * 10).rounded() / 10) s"
  }
}

/// Says in the unified log when the main thread stops returning to its run loop, which no
/// code on that thread can: for how long, and which probed values kept changing meanwhile
/// (``HangTrace``). Its own thread asks the main run loop for a beat twice a second.
public nonisolated final class MainThreadWatch: Sendable {
  /// The app's watch.
  public static let shared = MainThreadWatch()

  private struct State {
    var isRunning = false
    var lastBeat: TimeInterval
    var lastCheck: TimeInterval
    var sinceBeat = HangTrace.Tallies()
    var reports: StallReports
  }

  private let state: OSAllocatedUnfairLock<State>
  private let interval: TimeInterval
  private let write: @Sendable (String) -> Void
  private let onMain: @Sendable (@escaping @Sendable () -> Void) -> Void

  /// - Parameters:
  ///   - threshold: How long without a beat counts as a stall.
  ///   - interval: How often to ask for a beat.
  ///   - write: Receives each line.
  ///   - onMain: Runs a block when the main thread is next back at its run loop.
  init(
    threshold: TimeInterval = 1, interval: TimeInterval = 0.5,
    write: @escaping @Sendable (String) -> Void = HangLog.write,
    onMain: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = MainRunLoop.perform
  ) {
    let now = ProcessInfo.processInfo.systemUptime
    state = OSAllocatedUnfairLock(
      initialState: State(
        lastBeat: now, lastCheck: now, reports: StallReports(threshold: threshold)))
    self.interval = interval
    self.write = write
    self.onMain = onMain
  }

  /// Starts watching; a second call does nothing.
  public func start() {
    let starts = state.withLock { state in
      defer { state.isRunning = true }
      return !state.isRunning
    }
    guard starts else { return }
    Thread.detachNewThread { [self] in
      while state.withLock({ $0.isRunning }) {
        check()
        Thread.sleep(forTimeInterval: interval)
      }
    }
  }

  /// Stops watching.
  func stop() {
    state.withLock { $0.isRunning = false }
  }

  /// Asks the main thread for a beat and logs what the wait for the last one is worth. Time
  /// is the system's uptime, which a sleeping Mac does not advance.
  func check(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    onMain { [self] in beat() }
    let line = state.withLock { state -> String? in
      // This thread was held up itself (the process napped), so the wait says nothing.
      let wasHeld = now - state.lastCheck > max(1, interval * 4)
      state.lastCheck = now
      if wasHeld {
        state.lastBeat = now
        return nil
      }
      let since = state.sinceBeat
      return state.reports.check(silentFor: now - state.lastBeat) {
        HangTrace.busiest(since: since)
      }
    }
    if let line { write(line) }
  }

  /// The main thread answered.
  func beat(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    let tallies = HangTrace.tallies()
    state.withLock {
      $0.lastBeat = now
      $0.sinceBeat = tallies
    }
  }
}
