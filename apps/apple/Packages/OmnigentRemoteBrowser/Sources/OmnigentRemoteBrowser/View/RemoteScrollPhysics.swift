public import CoreGraphics
import Foundation
public import OmnigentCoreFFI

/// Scrolling a remote page from touch with `UIScrollView`'s feel (design doc section 16.4):
/// momentum computed here and sent as wheel deltas, rubber-banding at the page's edges, and the
/// scroll indicator. Pure values with time passed in, so they are unit-testable.
nonisolated public enum RemoteScrollPhysics {
  /// `UIScrollView.DecelerationRate.normal`: velocity kept per millisecond.
  public static let decelerationRate = 0.998
  /// Momentum stops below this speed, in points per second.
  public static let stopSpeed = 12.0
  /// `UIScrollView`'s rubber-band constant.
  public static let rubberBandConstant = 0.55

  /// How far content follows a finger dragged `offset` past an edge.
  /// - Parameters:
  ///   - offset: The finger's distance past the edge.
  ///   - dimension: The view's length on that axis.
  /// - Returns: The visible displacement, always less than `dimension`.
  public static func rubberBand(_ offset: Double, dimension: Double) -> Double {
    guard dimension > 0 else { return 0 }
    let magnitude = (1 - 1 / (abs(offset) * rubberBandConstant / dimension + 1)) * dimension
    return offset < 0 ? -magnitude : magnitude
  }

  /// A displacement after a rubber band is let go, `elapsed` seconds into springing back.
  /// - Parameters:
  ///   - displacement: Where it was let go.
  ///   - elapsed: Seconds since.
  /// - Returns: The displacement now; 0 once settled.
  public static func springBack(_ displacement: Double, elapsed: Double) -> Double {
    let remaining = displacement * exp(-elapsed * 14)
    return abs(remaining) < 0.5 ? 0 : remaining
  }

  /// Whether the page can scroll further in the direction content would move for a finger
  /// moving by `delta` (positive y: the finger moves down, revealing content above).
  /// - Parameters:
  ///   - delta: The finger's movement.
  ///   - metrics: The page's latest scroll metrics; `nil` assumes it can.
  /// - Returns: Per axis, whether the page can take the movement.
  public static func canScroll(by delta: CGPoint, metrics: RemoteScrollMetrics?) -> (
    x: Bool, y: Bool
  ) {
    guard let metrics else { return (true, true) }
    let maxX = max(0, metrics.contentWidth - metrics.viewportWidth)
    let maxY = max(0, metrics.contentHeight - metrics.viewportHeight)
    let horizontal =
      delta.x > 0 ? metrics.x > 0.5 : (delta.x < 0 ? metrics.x < maxX - 0.5 : true)
    let vertical = delta.y > 0 ? metrics.y > 0.5 : (delta.y < 0 ? metrics.y < maxY - 0.5 : true)
    return (horizontal, vertical)
  }
}

/// Momentum after a fling, decaying like `UIScrollView`'s.
nonisolated public struct RemoteMomentum: Hashable, Sendable {
  /// Velocity in points per second (the finger's: positive y moves content down).
  public private(set) var velocity: CGPoint

  /// Starts momentum.
  /// - Parameter velocity: The pan's velocity at release, points per second.
  public init(velocity: CGPoint) {
    self.velocity = velocity
  }

  /// Whether it has stopped.
  public var isFinished: Bool {
    hypot(velocity.x, velocity.y) < RemoteScrollPhysics.stopSpeed
  }

  /// Advances by `dt` seconds and returns the distance travelled in that time (the exact
  /// integral of the exponential decay).
  /// - Parameter interval: Seconds since the last step.
  /// - Returns: The displacement, points.
  public mutating func step(_ interval: Double) -> CGPoint {
    guard interval > 0, !isFinished else { return .zero }
    let rate = RemoteScrollPhysics.decelerationRate
    let decay = pow(rate, interval * 1000)
    // ∫ v·rate^(1000t) dt over the interval = v·(decay − 1) / (1000·ln rate).
    let factor = (decay - 1) / (1000 * log(rate))
    let moved = CGPoint(x: velocity.x * factor, y: velocity.y * factor)
    velocity = CGPoint(x: velocity.x * decay, y: velocity.y * decay)
    return moved
  }

  /// Stops one axis (it reached an edge).
  /// - Parameter vertical: The axis.
  public mutating func stop(vertical: Bool) {
    velocity = vertical ? CGPoint(x: velocity.x, y: 0) : CGPoint(x: 0, y: velocity.y)
  }
}

/// The vertical scroll indicator drawn over a mobile page (whose own scroll bars are hidden
/// overlay bars), and scrubbing by dragging it.
nonisolated public struct RemoteScrollIndicator: Hashable, Sendable {
  /// The indicator's width, points.
  public static let width = 5.0
  /// Its distance from the edge, points.
  public static let inset = 3.0
  /// The shortest thumb, points.
  public static let minimumLength = 36.0
  /// How far beside the thumb a touch still grabs it, points.
  public static let grabSlop = 20.0

  /// The thumb in view points, or `nil` when the page does not scroll vertically.
  public let thumb: CGRect
  /// The track the thumb moves along.
  public let track: CGRect

  /// The indicator for a page shown in `content` (the page's rectangle in the view).
  /// - Parameters:
  ///   - metrics: The page's scroll metrics.
  ///   - content: The page's rectangle in the view, points.
  public init?(metrics: RemoteScrollMetrics, content: CGRect) {
    let scrollable = metrics.contentHeight - metrics.viewportHeight
    guard scrollable > 1, scrollable.isFinite, metrics.contentHeight.isFinite,
      metrics.viewportHeight.isFinite, content.height > Self.minimumLength * 2
    else { return nil }
    let track = CGRect(
      x: content.maxX - Self.width - Self.inset, y: content.minY + Self.inset, width: Self.width,
      height: content.height - 2 * Self.inset)
    let length = max(
      Self.minimumLength, track.height * (metrics.viewportHeight / metrics.contentHeight))
    let progress = metrics.y.isNaN ? 0 : min(max(metrics.y / scrollable, 0), 1)
    self.track = track
    thumb = CGRect(
      x: track.minX, y: track.minY + (track.height - length) * progress, width: Self.width,
      height: length)
  }

  /// Whether a touch at `point` grabs the thumb.
  /// - Parameter point: View points.
  /// - Returns: Whether it is on (or just beside) the thumb.
  public func grabs(_ point: CGPoint) -> Bool {
    thumb.insetBy(dx: -Self.grabSlop, dy: -Self.grabSlop / 2).contains(point)
  }

  /// The page's vertical scroll offset that puts the thumb's centre at `y`.
  /// - Parameters:
  ///   - center: The thumb centre's view y.
  ///   - metrics: The page's scroll metrics.
  /// - Returns: The scroll offset, CSS px.
  public func scrollOffset(thumbCenterY center: Double, metrics: RemoteScrollMetrics) -> Double {
    let travel = track.height - thumb.height
    guard travel > 0 else { return metrics.y }
    let progress = min(max((center - thumb.height / 2 - track.minY) / travel, 0), 1)
    return progress * (metrics.contentHeight - metrics.viewportHeight)
  }
}
