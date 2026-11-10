import Foundation

/// Content heights a following transcript recently grew between. After a scroll to the bottom
/// the lazy rows above the viewport are estimated again, and in a short viewport the content can
/// fall back to where it was and grow to a height already reached, or to a new estimate from the
/// same start; following that would repeat every frame. New output grows on from where the last
/// growth ended, so only a repeat is let go.
nonisolated struct FollowedHeights {
  /// How long a height counts as recent after it last came back.
  static let memory: TimeInterval = 2

  private var reached: [Recent] = []
  private var starts: [Recent] = []

  private struct Recent {
    var height: CGFloat
    var seen: Date
  }

  /// Whether growth from `start` to `height` should be followed: not when the content reached
  /// `height`, or grew from `start`, within ``memory`` seconds. Remembers both either way.
  mutating func follows(_ height: CGFloat, from start: CGFloat, at now: Date = Date()) -> Bool {
    let wasReached = Self.remember(height, in: &reached, at: now)
    let wasStart = Self.remember(start, in: &starts, at: now)
    return !wasReached && !wasStart
  }

  /// Keeps `height` in `list`, dropping expired entries.
  /// - Returns: Whether it was there already.
  private static func remember(_ height: CGFloat, in list: inout [Recent], at now: Date) -> Bool {
    list.removeAll { now.timeIntervalSince($0.seen) > memory }
    if let index = list.firstIndex(where: { abs($0.height - height) < 1 }) {
      list[index].seen = now
      return true
    }
    list.append(Recent(height: height, seen: now))
    return false
  }
}
