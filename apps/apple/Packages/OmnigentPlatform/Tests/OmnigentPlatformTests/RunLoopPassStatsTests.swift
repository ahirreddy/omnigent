import Foundation
import Testing

@testable import OmnigentPlatform

struct RunLoopPassStatsTests {
  @Test func passesCountAgainstEachRefresh() {
    var stats = RunLoopPassStats()
    for duration in [0.002, 0.004, 0.009, 0.020, 0.001] { stats.record(duration) }
    stats.record(-1)
    #expect(stats.passes == 5)
    #expect(stats.over8ms == 2)
    #expect(stats.over16ms == 1)
    #expect(stats.worst == 0.020)
    #expect(abs(stats.busy - 0.036) < 1e-9)
  }

  @Test func percentilesAreNearestRank() {
    var stats = RunLoopPassStats()
    #expect(stats.percentile(0.5) == 0)
    for index in 1...20 { stats.record(Double(index) / 1000) }
    #expect(stats.percentile(0.5) == 0.010)
    #expect(stats.percentile(0.95) == 0.019)
    #expect(stats.percentile(1) == 0.020)
    #expect(stats.percentile(0) == 0.001)
  }

  @Test func summaryNamesEachNumber() {
    var stats = RunLoopPassStats()
    stats.record(0.002)
    stats.record(0.010)
    #expect(
      stats.summary
        == "loop.passes=2 loop.busy=12.0ms loop.p50=2.0ms loop.p95=10.0ms loop.p99=10.0ms"
        + " loop.>8.3ms=1 loop.>16.7ms=0 loop.worst=10.0ms")
  }
}
