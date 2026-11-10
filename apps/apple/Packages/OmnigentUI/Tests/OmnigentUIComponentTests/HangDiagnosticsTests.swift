import Foundation
import OSLog
import Testing
import os

@testable import OmnigentUIComponents

/// What every build keeps for the unified log: change counts, loop lines and stall lines.
@MainActor
@Suite("Hang diagnostics", .serialized)
struct HangDiagnosticsTests {
  private nonisolated final class Lines: Sendable {
    private let lines = OSAllocatedUnfairLock(initialState: [String]())

    var all: [String] { lines.withLock { $0 } }

    func add(_ line: String) {
      lines.withLock { $0.append(line) }
    }
  }

  /// Runs `body` with the probe's lines collected, or with no host listening.
  private func probing(listening: Bool = true, _ body: (Lines) -> Void) {
    let lines = Lines()
    let sink = LoopProbe.sink
    LoopProbe.reset()
    LoopProbe.sink = listening ? { lines.add($0) } : nil
    defer {
      LoopProbe.sink = sink
      LoopProbe.reset()
    }
    body(lines)
  }

  @Test("Change counts name what changed most since an earlier moment")
  func busiestSources() {
    #expect(HangTrace.busiest(since: HangTrace.tallies()) == "nothing probed")
    HangTrace.tally(.init(name: "test dock inset"))
    let before = HangTrace.tallies()
    for _ in 0..<3 { HangTrace.tally(.init(name: "test height", tag: 41)) }
    HangTrace.tally(.init(name: "test height", tag: 42))
    HangTrace.tally(.init(name: "test dock inset"))
    #expect(
      HangTrace.busiest(since: before) == "test height 41 +3, test dock inset +1, test height 42 +1"
    )
    #expect(HangTrace.tallies().count("test height", since: before) == 4)
  }

  @Test("The counts start again once too many values are probed, and a report says what came since")
  func countsStartAgain() {
    for _ in 0..<5 { HangTrace.tally(.init(name: "test counts")) }
    let before = HangTrace.tallies()
    for tag in 1...HangTrace.keptSources { HangTrace.tally(.init(name: "test row", tag: tag)) }
    for _ in 0..<7 { HangTrace.tally(.init(name: "test counts")) }
    // Five before and seven now: all seven came since the counts started again.
    #expect(HangTrace.tallies().count("test counts", since: before) == 7)
    #expect(HangTrace.busiest(since: before).contains("test counts +7"))
  }

  /// Changes twice as often as makes a busy second, for `seconds` seconds from `start`.
  private func change(
    _ name: String, tag: Int = 0, seconds: Int, from start: Date = Date(),
    detail: () -> String = { "x" }
  ) {
    let perSecond = LoopProbe.limit * 2
    for second in 0..<seconds {
      for index in 0..<perSecond {
        let offset = Double(second) + Double(index) / Double(perSecond) * 0.9
        LoopProbe.record(name, tag: tag, at: start.addingTimeInterval(offset), detail())
      }
    }
  }

  @Test("A loop's line names the view, and only the changes it lists are described")
  func loopLine() {
    probing { lines in
      let before = HangTrace.tallies()
      var described = 0
      change("test content height", tag: 7, seconds: LoopProbe.busySeconds) {
        described += 1
        return "\(described)"
      }
      #expect(
        lines.all == [
          "LOOP test content height 7 changed 30 times a second for 3 seconds: "
            + "1 | 2 | 3 | 4 | 5 | 6"
        ])
      #expect(described == LoopProbe.reportedChanges)
      #expect(HangTrace.busiest(since: before) == "test content height 7 +180")
    }
  }

  @Test("With no host listening a loop goes to the unified log, and counting goes on")
  func loopWithoutSink() {
    probing(listening: false) { _ in
      let before = HangTrace.tallies()
      change("test loop for the unified log", seconds: LoopProbe.busySeconds)
      #expect(HangTrace.busiest(since: before) == "test loop for the unified log +180")
    }
  }

  @Test("Loop counts start again once too many values are probed")
  func loopCountsStartAgain() {
    probing { lines in
      let start = Date()
      let third = start.addingTimeInterval(Double(LoopProbe.busySeconds - 1))
      change("test dock", seconds: LoopProbe.busySeconds - 1, from: start)
      for tag in 1...HangTrace.keptSources {
        LoopProbe.record("test row", tag: tag, at: third, "x")
      }
      // The two busy seconds before are forgotten, so a third does not make a loop.
      change("test dock", seconds: 1, from: third)
      #expect(lines.all.isEmpty)
      change("test dock", seconds: LoopProbe.busySeconds - 1, from: third.addingTimeInterval(1))
      #expect(lines.all.count == 1)
    }
  }

  private func line(_ reports: inout StallReports, _ silent: TimeInterval) -> String? {
    reports.check(silentFor: silent) { "dock +3" }
  }

  @Test("A stall is worth a line at the threshold, at each doubling, and when it ends")
  func stallLines() {
    var reports = StallReports(threshold: 2)
    #expect(line(&reports, 0.5) == nil)
    #expect(line(&reports, 1.9) == nil)
    #expect(line(&reports, 2.04) == "STALL main thread busy for 2.0 s; changed meanwhile: dock +3")
    #expect(line(&reports, 2.5) == nil)
    #expect(line(&reports, 3.9) == nil)
    #expect(line(&reports, 4.4) == "STALL main thread busy for 4.4 s; changed meanwhile: dock +3")
    #expect(line(&reports, 7.26) == nil)
    #expect(line(&reports, 0.1) == "STALL ended: the main thread was busy for 7.3 s")
    #expect(line(&reports, 0.6) == nil)
  }

  @Test("A stall that never ends, and a run of many stalls, stop being logged")
  func stallLinesAreBounded() {
    var reports = StallReports(threshold: 1)
    let lines = (1...4000).compactMap { line(&reports, Double($0)) }
    #expect(lines.count == StallReports.reportsPerStall)
    #expect(lines.last?.contains("busy for 16.0 s") == true)
    #expect(line(&reports, 0)?.hasPrefix("STALL ended") == true)

    var stalls = 0
    for _ in 0..<(StallReports.stallsReported + 5) {
      if line(&reports, 1.5) != nil { stalls += 1 }
      _ = line(&reports, 0)
    }
    #expect(stalls == StallReports.stallsReported - 1)
  }

  /// A watch whose beats the test runs by hand.
  private nonisolated final class Beats: Sendable {
    private let waiting = OSAllocatedUnfairLock(initialState: [@Sendable () -> Void]())

    func add(_ beat: @escaping @Sendable () -> Void) {
      waiting.withLock { $0.append(beat) }
    }

    /// Runs the latest beat asked for, as the main thread returning to its run loop does.
    func answer() {
      let latest = waiting.withLock { $0.last }
      latest?()
    }
  }

  @Test("The watch logs a main thread that stops answering, with what kept changing")
  func watchReportsStall() {
    let lines = Lines()
    let beats = Beats()
    let watch = MainThreadWatch(
      threshold: 2, interval: 0.5, write: { lines.add($0) }, onMain: { beats.add($0) })
    let start = ProcessInfo.processInfo.systemUptime
    watch.check(at: start + 0.5)
    watch.beat(at: start + 0.4)
    for _ in 0..<40 { HangTrace.tally(.init(name: "test content height", tag: 9)) }
    for step in 2...6 { watch.check(at: start + Double(step) * 0.5) }
    #expect(
      lines.all == [
        "STALL main thread busy for 2.1 s; changed meanwhile: test content height 9 +40"
      ])
    beats.answer()
    watch.beat(at: start + 3.2)
    watch.check(at: start + 3.5)
    #expect(lines.all.last == "STALL ended: the main thread was busy for 2.6 s")
  }

  @Test("A stall after rows change, older rows land or the reader jumps names each of them")
  func stallNamesRowChangesAndJumps() {
    let lines = Lines()
    let watch = MainThreadWatch(
      threshold: 1, interval: 0.5, write: { lines.add($0) }, onMain: { _ in })
    let scroll = TranscriptScrollState()
    let start = ProcessInfo.processInfo.systemUptime
    watch.check(at: start + 0.5)
    watch.beat(at: start + 0.5)
    scroll.contentChanged()
    scroll.contentChanged()
    scroll.firstRowChanged()
    scroll.jumped(to: TranscriptView.bottomID)
    watch.check(at: start + 1)
    watch.check(at: start + 1.6)
    let changed = [
      ("transcript rows changed", 2), ("transcript first row", 1), ("transcript jump", 1),
    ]
    .map { "\(HangTrace.Source(name: $0.0, tag: scroll.probeTag).label) +\($0.1)" }
    #expect(
      lines.all == [
        "STALL main thread busy for 1.1 s; changed meanwhile: \(changed.joined(separator: ", "))"
      ])
  }

  @Test("A watch given no writer sends its lines where the documented log predicate finds them")
  func watchWritesToTheLog() throws {
    let watch = MainThreadWatch(threshold: 1, onMain: { _ in })
    let asked = Date()
    watch.check(at: ProcessInfo.processInfo.systemUptime + 1.5)
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let entries = try store.getEntries(
      at: store.position(date: asked.addingTimeInterval(-1)),
      matching: NSPredicate(
        format: "subsystem == %@ AND category == %@", "ai.omnigent.performance", "hang"))
    let stalls = entries.map(\.composedMessage).filter {
      $0.hasPrefix("STALL main thread busy for 1.5 s; changed meanwhile: ")
    }
    #expect(!stalls.isEmpty)
  }

  @Test("A watch that was itself held up, as a napping process is, reports nothing")
  func watchHeldUp() {
    let lines = Lines()
    let watch = MainThreadWatch(
      threshold: 2, interval: 0.5, write: { lines.add($0) }, onMain: { _ in })
    let start = ProcessInfo.processInfo.systemUptime
    watch.check(at: start + 0.5)
    watch.check(at: start + 600)
    watch.check(at: start + 600.5)
    #expect(lines.all.isEmpty)
  }

  @Test("A started watch beats the main run loop from its own thread until stopped")
  func watchRuns() async throws {
    let lines = Lines()
    let asked = Lines()
    let watch = MainThreadWatch(
      threshold: 60, interval: 0.01, write: { lines.add($0) },
      onMain: { beat in
        asked.add("beat")
        MainRunLoop.perform(beat)
      })
    watch.start()
    watch.start()
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while asked.all.count < 3, clock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    watch.stop()
    #expect(asked.all.count >= 3)
    #expect(lines.all.isEmpty)
    try await Task.sleep(for: .milliseconds(50))
    let stopped = asked.all.count
    try await Task.sleep(for: .milliseconds(50))
    #expect(asked.all.count == stopped)
  }

  @Test("A block for the main run loop runs once the main thread is back at it")
  func mainRunLoopBlock() {
    let ran = Lines()
    MainRunLoop.perform { ran.add("ran") }
    #expect(ran.all.isEmpty)
    CFRunLoopRunInMode(.defaultMode, 0.02, false)
    #expect(ran.all == ["ran"])
    // The app's own watch asks the same way, and finds this thread answering.
    MainThreadWatch.shared.check()
    CFRunLoopRunInMode(.defaultMode, 0.02, false)
  }
}
