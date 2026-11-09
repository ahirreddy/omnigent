public import CoreGraphics
public import OmnigentCoreFFI

/// Client-side zoom and pan of the remote video (design doc section 16.3). The zoomed page is the
/// fit rectangle scaled by `scale` and moved by `offset`; input maps through the same transform
/// (`apply(to:)`), so a tap lands on the pixel under the finger at any zoom. The stream itself
/// never changes.
nonisolated public struct RemoteZoomState: Hashable, Sendable {
  /// The largest zoom.
  public static let maxScale = 5.0
  /// The zoom a double tap goes to.
  public static let doubleTapScale = 2.5

  /// Zoom relative to the fit; 1 is the whole page. Briefly outside 1…`maxScale` while a pinch
  /// rubber-bands.
  public private(set) var scale = 1.0
  /// The zoomed page's origin minus the fit rectangle's origin, in view points.
  public private(set) var offset = CGPoint.zero

  /// No zoom.
  public init() {}

  /// Whether the page is magnified.
  public var isZoomed: Bool { scale > 1.001 }

  /// The zoomed page's rectangle in the view.
  /// - Parameter fit: The page's unzoomed (letterboxed) rectangle.
  /// - Returns: The rectangle.
  public func contentRect(fit: CGRect) -> CGRect {
    CGRect(
      x: fit.minX + offset.x, y: fit.minY + offset.y, width: fit.width * scale,
      height: fit.height * scale)
  }

  /// The geometry with this zoom applied; its point and length mappings include the zoom.
  /// - Parameter geometry: The unzoomed fit.
  /// - Returns: The zoomed geometry.
  public func apply(to geometry: RemoteViewportGeometry) -> RemoteViewportGeometry {
    var zoomed = geometry
    zoomed.contentRect = contentRect(fit: geometry.contentRect)
    zoomed.scale = geometry.scale * scale
    return zoomed
  }

  /// Zooms by `factor` keeping the page point under `anchor` fixed.
  /// - Parameters:
  ///   - factor: The relative change (a pinch's scale since its last change).
  ///   - anchor: The view point that stays put (the pinch centroid).
  ///   - fit: The unzoomed page rectangle.
  ///   - bounds: The view size.
  ///   - elastic: Rubber-band beyond the limits (during a pinch) instead of clamping.
  public mutating func zoom(
    by factor: Double, anchor: CGPoint, fit: CGRect, bounds: CGSize, elastic: Bool = false
  ) {
    guard factor.isFinite, factor > 0, anchor.x.isFinite, anchor.y.isFinite else { return }
    let wanted =
      elastic ? Self.resisted(scale * factor) : min(max(scale * factor, 1), Self.maxScale)
    let rect = contentRect(fit: fit)
    let ratio = wanted / scale
    let origin = CGPoint(
      x: anchor.x - (anchor.x - rect.minX) * ratio, y: anchor.y - (anchor.y - rect.minY) * ratio)
    scale = wanted
    offset = CGPoint(x: origin.x - fit.minX, y: origin.y - fit.minY)
    if !elastic { clamp(fit: fit, bounds: bounds) }
  }

  /// Ends a pinch: back within 1…`maxScale` and inside the view.
  /// - Parameters:
  ///   - anchor: The last pinch centroid.
  ///   - fit: The unzoomed page rectangle.
  ///   - bounds: The view size.
  public mutating func settle(anchor: CGPoint, fit: CGRect, bounds: CGSize) {
    if scale <= 1 {
      self = Self()
      return
    }
    zoom(by: 1, anchor: anchor, fit: fit, bounds: bounds)
  }

  /// Pans the zoomed page; the part it cannot move (at an edge, or unzoomed) is returned so
  /// the caller scrolls the page with it, as Safari chains the visual and layout viewports.
  /// - Parameters:
  ///   - delta: The finger's movement in view points.
  ///   - fit: The unzoomed page rectangle.
  ///   - bounds: The view size.
  /// - Returns: The movement left over, in view points.
  public mutating func pan(by delta: CGPoint, fit: CGRect, bounds: CGSize) -> CGPoint {
    let before = offset
    offset = CGPoint(x: offset.x + delta.x, y: offset.y + delta.y)
    clamp(fit: fit, bounds: bounds)
    return CGPoint(x: delta.x - (offset.x - before.x), y: delta.y - (offset.y - before.y))
  }

  /// A double tap: back to the whole page when zoomed, else `doubleTapScale` at the tap.
  /// - Parameters:
  ///   - point: The tap.
  ///   - fit: The unzoomed page rectangle.
  ///   - bounds: The view size.
  public mutating func toggle(at point: CGPoint, fit: CGRect, bounds: CGSize) {
    if isZoomed {
      self = Self()
    } else {
      zoom(by: Self.doubleTapScale, anchor: point, fit: fit, bounds: bounds)
    }
  }

  /// Keeps the zoomed page covering the view, or centred on an axis where it is smaller.
  /// - Parameters:
  ///   - fit: The unzoomed page rectangle.
  ///   - bounds: The view size.
  public mutating func clamp(fit: CGRect, bounds: CGSize) {
    let rect = contentRect(fit: fit)
    func axis(_ origin: Double, _ length: Double, _ available: Double) -> Double {
      length <= available ? (available - length) / 2 : min(max(origin, available - length), 0)
    }
    let left = axis(rect.minX, rect.width, bounds.width)
    let top = axis(rect.minY, rect.height, bounds.height)
    offset = CGPoint(x: left - fit.minX, y: top - fit.minY)
  }

  /// Scale beyond the limits with resistance, as `UIScrollView` bounces a pinch.
  private static func resisted(_ scale: Double) -> Double {
    if scale < 1 { return max(0.5, 1 - (1 - scale) * 0.3) }
    if scale > maxScale { return min(maxScale + (scale - maxScale) * 0.3, maxScale * 2) }
    return scale
  }
}

/// Where a touch on the page should go.
nonisolated public enum RemoteTouchRegions {
  /// The width of a classic scroll bar in CSS px (Chromium on Linux and Windows).
  public static let scrollBarWidth = 16.0
  /// The smallest touch target, in view points.
  public static let minimumTarget = 22.0

  /// Whether a CSS point is on the page's own scroll bar, so a drag that starts there should
  /// grab the thumb (a mouse drag) instead of scrolling.
  /// - Parameters:
  ///   - point: CSS px.
  ///   - viewport: The remote viewport.
  ///   - pointsPerCSS: View points per CSS px (the zoomed geometry's scale).
  ///   - scroll: The page's scroll metrics, when reported: a bar exists only on a scrolling axis.
  /// - Returns: Whether the point is on a scroll bar.
  public static func isOnScrollBar(
    css point: CGPoint, viewport: RemoteViewport, pointsPerCSS: Double,
    scroll: RemoteScrollMetrics?
  ) -> Bool {
    let band = max(scrollBarWidth, minimumTarget / max(pointsPerCSS, 0.01))
    let vertical = scroll.map { $0.contentHeight > $0.viewportHeight + 1 } ?? true
    let horizontal = scroll.map { $0.contentWidth > $0.viewportWidth + 1 } ?? false
    return (vertical && point.x >= Double(viewport.width) - band)
      || (horizontal && point.y >= Double(viewport.height) - band)
  }
}
