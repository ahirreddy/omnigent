import Foundation
import Testing

@testable import OmnigentStores

@Suite("Turn timer")
struct TurnTimerTests {
  private let start = Date(timeIntervalSince1970: 1_000)

  @Test("A turn seen to start is timed until it settles, under each of its response ids")
  func timesObservedTurn() {
    var timer = TurnTimer()
    timer.update(isRunning: false, observed: false, responseIDs: [], now: start)
    timer.update(isRunning: true, observed: true, responseIDs: [], now: start)
    #expect(timer.startedAt == start)
    timer.update(
      isRunning: true, observed: true, responseIDs: ["r1"], now: start.addingTimeInterval(5))
    #expect(timer.startedAt == start, "later updates keep the start")
    timer.update(
      isRunning: false, observed: true, responseIDs: ["r1", "r2"],
      now: start.addingTimeInterval(12))
    #expect(timer.startedAt == nil)
    #expect(timer.durations == ["r1": 12, "r2": 12])
  }

  @Test("A turn already running when the conversation opens has no start and no duration")
  func unobservedTurn() {
    var timer = TurnTimer()
    timer.update(isRunning: true, observed: false, responseIDs: [], now: start)
    #expect(timer.startedAt == nil)
    timer.update(
      isRunning: false, observed: true, responseIDs: ["r1"], now: start.addingTimeInterval(9))
    #expect(timer.durations.isEmpty)
  }

  @Test("A snapshot mid-turn keeps the start it already had")
  func snapshotKeepsStart() {
    var timer = TurnTimer()
    timer.update(isRunning: true, observed: true, responseIDs: [], now: start)
    timer.update(
      isRunning: true, observed: false, responseIDs: [], now: start.addingTimeInterval(3))
    #expect(timer.startedAt == start)
  }
}
