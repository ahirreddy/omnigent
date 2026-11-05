import Foundation
import Testing

@testable import OmnigentPlatform

struct FrameStatsTests {
  private static let at60: TimeInterval = 1.0 / 60
  private static let at120: TimeInterval = 1.0 / 120

  @Test func steadyFramesAtSixtyHertzHaveNoHitches() {
    var stats = FrameStats()
    for _ in 0..<60 { stats.record(interval: Self.at60, expected: Self.at60) }
    #expect(stats.frames == 60)
    #expect(abs(stats.framesPerSecond - 60) < 0.01)
    #expect(stats.hitchTime == 0)
    #expect(stats.dropped == 0)
    #expect(stats.over16ms == 0)
    // Every 60 Hz frame misses a 120 Hz refresh.
    #expect(stats.over8ms == 60)
  }

  @Test func jitterOnTimeIsNotALongFrame() {
    var stats = FrameStats()
    stats.record(interval: Self.at60 + 0.0005, expected: Self.at60)
    stats.record(interval: Self.at120 + 0.0005, expected: Self.at120)
    #expect(stats.over16ms == 0)
    #expect(stats.over8ms == 1)
    #expect(stats.hitchTime == 0)
  }

  @Test func aLateFrameCountsItsHitchTimeAndDroppedRefreshes() {
    var stats = FrameStats()
    stats.record(interval: Self.at60, expected: Self.at60)
    // Three refreshes long: two dropped, 33 ms later than one refresh.
    stats.record(interval: Self.at60 * 3, expected: Self.at60)
    #expect(stats.dropped == 2)
    #expect(abs(stats.hitchTime - Self.at60 * 2) < 1e-9)
    #expect(stats.over16ms == 1)
    #expect(stats.over33ms == 1)
    #expect(abs(stats.worst - Self.at60 * 3) < 1e-9)
    // 33.3 ms of hitches over 66.7 ms is 500 ms per second.
    #expect(abs(stats.hitchRatio - 500) < 0.01)
  }

  @Test func oneDroppedRefreshAtOneTwentyHertz() {
    var stats = FrameStats()
    stats.record(interval: Self.at120 * 2, expected: Self.at120)
    #expect(stats.dropped == 1)
    #expect(stats.over8ms == 1)
    #expect(stats.over16ms == 0)
    #expect(stats.refresh == Self.at120)
  }

  @Test func ignoresEmptyIntervals() {
    var stats = FrameStats()
    stats.record(interval: 0, expected: Self.at60)
    stats.record(interval: Self.at60, expected: 0)
    #expect(stats == FrameStats())
    #expect(stats.framesPerSecond == 0)
    #expect(stats.hitchRatio == 0)
  }

  @Test func summaryNamesEachNumber() {
    var stats = FrameStats()
    stats.record(interval: Self.at60, expected: Self.at60)
    stats.record(interval: 0.05, expected: Self.at60)
    #expect(
      stats.summary
        == "fps=30.0 frames=2 hitch=500.0ms/s dropped=2 >8.3ms=2 >16.7ms=1 >33ms=1"
        + " worst=50.0ms refresh=16.7ms")
  }
}
