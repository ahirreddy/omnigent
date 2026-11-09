import Foundation
import Testing

@testable import OmnigentPlatform

struct HostileFrameStatsTests {
  private static let at60: TimeInterval = 1.0 / 60

  @Test func intervalsThatAreNotPositiveNumbersAreIgnored() {
    var stats = FrameStats()
    for interval in [0, -1, .nan, -.infinity, -.leastNonzeroMagnitude] as [TimeInterval] {
      stats.record(interval: interval, expected: Self.at60)
      stats.record(interval: Self.at60, expected: interval)
    }
    #expect(stats == FrameStats())
  }

  @Test func aSlowFrameAgainstAnInfiniteRefreshIsNotAHitch() {
    var stats = FrameStats()
    stats.record(interval: 1, expected: .infinity)
    #expect(stats.frames == 1)
    #expect(stats.dropped == 0)
    #expect(stats.refresh == .infinity)
    #expect(stats.summary.contains("refresh=inf"))
  }

  @Test
  func anInfiniteIntervalDoesNotTrap() {
    var stats = FrameStats()
    stats.record(interval: .infinity, expected: Self.at60)
    #expect(stats.frames == 1)
  }

  @Test
  func anIntervalManyRefreshesLongDoesNotTrap() {
    var stats = FrameStats()
    stats.record(interval: 1, expected: 1e-300)
    #expect(stats.frames == 1)
  }

  @Test
  func droppedFramesDoNotOverflow() {
    var stats = FrameStats()
    for _ in 0..<3 { stats.record(interval: 4e18, expected: 1) }
    #expect(stats.frames == 3)
  }

  @Test func aLongIntervalThatFitsIsCounted() {
    var stats = FrameStats()
    stats.record(interval: 1e6, expected: 1e-6)
    #expect(stats.dropped == 999_999_999_999)
    #expect(stats.worst == 1e6)
    #expect(stats.over33ms == 1)
  }

  @Test func tinyFramesAreCountedWithoutFalseLongFrames() {
    var stats = FrameStats()
    let tiny = TimeInterval.leastNonzeroMagnitude
    stats.record(interval: tiny, expected: tiny)
    #expect(stats.frames == 1)
    #expect(stats.over8ms == 0)
    #expect(stats.dropped == 0)
    // The rate of a frame this short does not fit a Double.
    #expect(stats.framesPerSecond == .infinity)
    #expect(stats.hitchRatio == 0)
    #expect(stats.summary.contains("fps=inf"))
  }

  @Test func theRefreshKeepsTheShortestAndTheWorstKeepsTheLongest() {
    var stats = FrameStats()
    stats.record(interval: Self.at60, expected: Self.at60)
    stats.record(interval: 1.0 / 120, expected: 1.0 / 120)
    stats.record(interval: Self.at60, expected: Self.at60)
    #expect(stats.refresh == 1.0 / 120)
    #expect(stats.worst == Self.at60)
  }

  @Test func eachThresholdExcludesItsTolerance() {
    let tolerance = FrameStats.tolerance
    let counts = [1.0 / 120 + tolerance, 1.0 / 60 + tolerance, 1.0 / 30 + tolerance].map { edge in
      var stats = FrameStats()
      stats.record(interval: edge, expected: edge)
      return [stats.over8ms, stats.over16ms, stats.over33ms]
    }
    #expect(counts == [[0, 0, 0], [1, 0, 0], [1, 1, 0]])
    var past = FrameStats()
    past.record(interval: 1.0 / 30 + tolerance + 1e-9, expected: 1)
    #expect(past.over33ms == 1)
  }

  @Test func aFrameExactlyOneAndAHalfRefreshesLongIsNotAHitch() {
    var stats = FrameStats()
    stats.record(interval: 1.5, expected: 1)
    #expect(stats.hitchTime == 0)
    stats.record(interval: 1.5000001, expected: 1)
    #expect(stats.dropped == 1)
  }

  @Test func theSummaryNamesEveryField() {
    var stats = FrameStats()
    #expect(stats.summary.hasPrefix("fps=0.0 frames=0 hitch=0.0ms/s dropped=0"))
    stats.record(interval: Self.at60 * 3, expected: Self.at60)
    for field in [
      "fps=", "frames=1", "hitch=", "dropped=2", ">8.3ms=1", ">16.7ms=1", ">33ms=1", "worst=",
      "refresh=",
    ] {
      #expect(stats.summary.contains(field), "\(field)")
    }
  }
}

struct PerformanceSignpostTests {
  private struct Failure: Error {}

  @Test func measureReturnsWhatItsBodyReturnsAndNests() {
    let result = PerformanceSignposts.measure(PerformanceSignposts.transcript, "outer") {
      PerformanceSignposts.measure(PerformanceSignposts.transcript, "inner") { 7 }
    }
    #expect(result == 7)
    #expect(PerformanceSignposts.subsystem == "ai.omnigent.performance")
  }

  @Test func measureRethrowsAndClosesItsInterval() {
    #expect(throws: Failure.self) {
      try PerformanceSignposts.measure(PerformanceSignposts.transcript, "throws") {
        throw Failure()
      }
    }
    // The interval closed: another one runs after the throw.
    #expect(PerformanceSignposts.measure(PerformanceSignposts.transcript, "after") { true })
  }
}

struct PlatformErrorTests {
  @Test func theDescriptionNamesTheURL() throws {
    let url = try #require(URL(string: "omnigent-test:%00%E2%80%AE"))
    #expect(PlatformError.cannotOpenURL(url).description.hasSuffix(url.absoluteString))
    #expect(PlatformError.cannotOpenURL(url) == .cannotOpenURL(url))
  }
}
