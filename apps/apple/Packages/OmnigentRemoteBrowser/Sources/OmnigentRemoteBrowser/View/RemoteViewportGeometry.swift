public import CoreGraphics
public import OmnigentCoreFFI

/// Where the remote viewport sits in a view (the core's `remoteViewportPlacement`: letterboxed,
/// scaled to fit, centered), and the mapping between view points (top-left origin) and the
/// viewport's CSS pixels. The device pixel ratio changes the video's pixel size, never CSS
/// coordinates.
nonisolated public struct RemoteViewportGeometry: Hashable, Sendable {
  /// The viewport.
  public var viewport: RemoteViewport
  /// The rectangle the page occupies in the view.
  public var contentRect: CGRect
  /// View points per CSS pixel.
  public var scale: Double

  /// Fits `viewport` into a view; `nil` for an empty view or viewport.
  /// - Parameters:
  ///   - viewport: The remote viewport.
  ///   - bounds: The view size.
  public init?(viewport: RemoteViewport, bounds: CGSize) {
    guard
      let placement = remoteViewportPlacement(
        viewport: viewport, viewWidth: bounds.width, viewHeight: bounds.height)
    else { return nil }
    self.viewport = viewport
    scale = placement.scale
    contentRect = CGRect(
      x: placement.x, y: placement.y, width: placement.width, height: placement.height)
  }

  /// The viewport implied by a video picture when the host has not reported one.
  /// - Parameters:
  ///   - videoSize: Decoded size in video pixels.
  ///   - deviceScale: The DPR the host encodes at.
  /// - Returns: The viewport.
  public static func viewport(videoSize: CGSize, deviceScale: Double = 1) -> RemoteViewport {
    let ratio = deviceScale > 0 && deviceScale.isFinite ? deviceScale : 1
    return RemoteViewport(
      width: wholePixels(videoSize.width / ratio), height: wholePixels(videoSize.height / ratio),
      dpr: ratio)
  }

  /// `length` as whole pixels, zero when it is not a number.
  private static func wholePixels(_ length: Double) -> UInt32 {
    guard !length.isNaN else { return 0 }
    return UInt32(min(max(length.rounded(), 0), Double(UInt32.max)))
  }

  /// The CSS point under a view point.
  /// - Parameters:
  ///   - point: View point, top-left origin.
  ///   - clamped: Clamp to the viewport instead of returning `nil` outside it (drags, releases).
  /// - Returns: CSS pixels, or `nil` when outside and not clamped.
  public func cssPoint(for point: CGPoint, clamped: Bool = false) -> CGPoint? {
    let cssX = (point.x - contentRect.minX) / scale
    let cssY = (point.y - contentRect.minY) / scale
    let width = Double(viewport.width)
    let height = Double(viewport.height)
    if clamped {
      func inside(_ value: Double, _ length: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), length - 1)
      }
      return CGPoint(x: inside(cssX, width), y: inside(cssY, height))
    }
    guard cssX >= 0, cssY >= 0, cssX < width, cssY < height else { return nil }
    return CGPoint(x: cssX, y: cssY)
  }

  /// The view point showing a CSS point.
  /// - Parameter point: CSS pixels.
  /// - Returns: View point, top-left origin.
  public func viewPoint(for point: CGPoint) -> CGPoint {
    CGPoint(x: contentRect.minX + point.x * scale, y: contentRect.minY + point.y * scale)
  }

  /// A view-space distance in CSS pixels (scroll deltas).
  /// - Parameter points: Distance in view points.
  /// - Returns: Distance in CSS pixels.
  public func cssLength(_ points: Double) -> Double {
    points / scale
  }
}
