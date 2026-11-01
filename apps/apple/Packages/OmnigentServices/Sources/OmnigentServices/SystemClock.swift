import Foundation
public import OmnigentCoreFFI

/// `Clock` host implementation: `ContinuousClock` for monotonic time, `Date` for wall time.
public final class SystemClock: Clock, Sendable {
  /// The fixed origin for monotonic time, fixed on first use for the whole process.
  private static let origin = ContinuousClock.now

  /// Creates a clock.
  public init() {}

  /// Monotonic milliseconds since the process origin. Continues across sleep like the
  /// continuous clock it reads.
  public func monotonicMs() -> UInt64 {
    let elapsed = ContinuousClock.now - Self.origin
    return UInt64(max(0, elapsed / .milliseconds(1)))
  }

  /// Milliseconds since the Unix epoch, for token expiry.
  public func unixTimeMs() -> UInt64 {
    UInt64(max(0, (Date().timeIntervalSince1970 * 1000).rounded(.down)))
  }
}
