import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentServices

@Suite struct SystemEntropySourceTests {
  @Test func returnsTheRequestedLengthOfVaryingBytes() throws {
    let source = SystemEntropySource()
    let first = try source.randomBytes(len: 32)
    let second = try source.randomBytes(len: 32)
    #expect(first.count == 32)
    #expect(second.count == 32)
    #expect(first != second)
  }

  @Test func zeroLengthReturnsNoBytes() throws {
    let empty = try SystemEntropySource().randomBytes(len: 0)
    #expect(empty.isEmpty)
  }
}

// `spawn` takes a Rust-created CoreTask, which only the core can construct, so it is covered by
// the core's integration tests rather than here.
@Suite struct SchedulerAndClockTests {
  @Test func sleepCompletesAfterItsDelay() async {
    let started = ContinuousClock.now
    await TaskScheduler().sleep(delayMs: 30)
    #expect(ContinuousClock.now - started >= .milliseconds(30))
  }

  @Test func cancellingTheCallerEndsTheSleepPromptly() async {
    let scheduler = TaskScheduler()
    let task = Task { await scheduler.sleep(delayMs: 60_000) }
    let started = ContinuousClock.now
    task.cancel()
    await task.value
    #expect(ContinuousClock.now - started < .seconds(5))
  }

  @Test func clockIsMonotonicAndTracksWallTime() {
    let clock = SystemClock()
    let first = clock.monotonicMs()
    let second = clock.monotonicMs()
    #expect(second >= first)
    let wall = UInt64(Date().timeIntervalSince1970 * 1000)
    let reported = clock.unixTimeMs()
    #expect(reported <= wall + 1000 && wall <= reported + 1000)
  }
}
