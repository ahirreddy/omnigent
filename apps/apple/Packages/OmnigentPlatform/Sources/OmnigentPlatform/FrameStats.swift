public import Foundation

/// Frame pacing over a run of display refreshes, from the time between frames the main thread
/// delivered: frame rate, long frames, hitch time and the worst frame.
///
/// A frame is a hitch when it arrives more than half a refresh late; its hitch time is how much
/// longer than one refresh it took. The hitch-time ratio is hitch milliseconds per second.
nonisolated public struct FrameStats: Sendable, Equatable {
  /// Frames delivered.
  public private(set) var frames = 0
  /// Seconds the frames covered.
  public private(set) var duration: TimeInterval = 0
  /// Seconds frames arrived later than one refresh, summed over the hitches.
  public private(set) var hitchTime: TimeInterval = 0
  /// Refreshes that delivered no frame.
  public private(set) var dropped = 0
  /// Frames longer than 8.3 ms (a missed 120 Hz refresh).
  public private(set) var over8ms = 0
  /// Frames longer than 16.7 ms (a missed 60 Hz refresh).
  public private(set) var over16ms = 0
  /// Frames longer than 33.3 ms.
  public private(set) var over33ms = 0
  /// The longest frame, in seconds.
  public private(set) var worst: TimeInterval = 0
  /// The shortest refresh interval the display asked for, in seconds; 0 before the first frame.
  public private(set) var refresh: TimeInterval = 0

  /// Jitter allowed above each threshold, so a frame on time is not counted as long.
  static let tolerance: TimeInterval = 0.001

  /// Creates empty stats.
  public init() {}

  /// Adds one frame.
  /// - Parameters:
  ///   - interval: Seconds since the previous frame.
  ///   - expected: The refresh interval the display expected for it.
  public mutating func record(interval: TimeInterval, expected: TimeInterval) {
    guard interval > 0, expected > 0 else { return }
    frames += 1
    duration += interval
    worst = max(worst, interval)
    refresh = refresh == 0 ? expected : min(refresh, expected)
    if interval > 1.0 / 120 + Self.tolerance { over8ms += 1 }
    if interval > 1.0 / 60 + Self.tolerance { over16ms += 1 }
    if interval > 1.0 / 30 + Self.tolerance { over33ms += 1 }
    if interval > expected * 1.5 {
      hitchTime += interval - expected
      dropped += max(Int((interval / expected).rounded()) - 1, 1)
    }
  }

  /// Frames per second.
  public var framesPerSecond: Double { duration > 0 ? Double(frames) / duration : 0 }

  /// Hitch milliseconds per second.
  public var hitchRatio: Double { duration > 0 ? hitchTime * 1000 / duration : 0 }

  /// One line for the log: `fps=59.8 frames=60 hitch=12.0ms/s dropped=1 >8.3ms=60 ...`.
  public var summary: String {
    "fps=\(Self.tenths(framesPerSecond)) frames=\(frames) hitch=\(Self.tenths(hitchRatio))ms/s"
      + " dropped=\(dropped) >8.3ms=\(over8ms) >16.7ms=\(over16ms) >33ms=\(over33ms)"
      + " worst=\(Self.tenths(worst * 1000))ms refresh=\(Self.tenths(refresh * 1000))ms"
  }

  private static func tenths(_ value: Double) -> Double {
    (value * 10).rounded() / 10
  }
}
