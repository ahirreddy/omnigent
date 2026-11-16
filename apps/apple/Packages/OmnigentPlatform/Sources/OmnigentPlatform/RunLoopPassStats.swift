public import Foundation

/// How long the main thread's run-loop passes took, from each wake-up to the next wait: where a
/// frame's work, layout and commit happen. A pass longer than a refresh (8.3 ms at 120 Hz,
/// 16.7 ms at 60 Hz) can miss it, which a simulator's 60 Hz frames don't show.
nonisolated public struct RunLoopPassStats: Sendable, Equatable {
  /// Passes recorded.
  public private(set) var passes = 0
  /// Seconds the passes took, summed.
  public private(set) var busy: TimeInterval = 0
  /// Passes longer than 8.3 ms.
  public private(set) var over8ms = 0
  /// Passes longer than 16.7 ms.
  public private(set) var over16ms = 0
  /// The longest pass, in seconds.
  public private(set) var worst: TimeInterval = 0
  private var durations: [TimeInterval] = []

  /// Creates empty stats.
  public init() {}

  /// Adds one pass.
  /// - Parameter duration: Seconds from the wake-up to the wait.
  public mutating func record(_ duration: TimeInterval) {
    guard duration >= 0 else { return }
    passes += 1
    busy += duration
    worst = max(worst, duration)
    if duration > 1.0 / 120 { over8ms += 1 }
    if duration > 1.0 / 60 { over16ms += 1 }
    durations.append(duration)
  }

  /// The pass duration that `fraction` of the passes took at most (0.95 for the 95th
  /// percentile), in seconds; 0 without passes.
  public func percentile(_ fraction: Double) -> TimeInterval {
    guard !durations.isEmpty else { return 0 }
    let sorted = durations.sorted()
    let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
    return sorted[min(max(rank, 0), sorted.count - 1)]
  }

  /// One line for the log: `loop.passes=118 loop.busy=420.5ms loop.p50=1.2ms ...`.
  public var summary: String {
    "loop.passes=\(passes) loop.busy=\(Self.milliseconds(busy))ms"
      + " loop.p50=\(Self.milliseconds(percentile(0.5)))ms"
      + " loop.p95=\(Self.milliseconds(percentile(0.95)))ms"
      + " loop.p99=\(Self.milliseconds(percentile(0.99)))ms"
      + " loop.>8.3ms=\(over8ms) loop.>16.7ms=\(over16ms)"
      + " loop.worst=\(Self.milliseconds(worst))ms"
  }

  private static func milliseconds(_ seconds: TimeInterval) -> Double {
    (seconds * 10_000).rounded() / 10
  }
}
