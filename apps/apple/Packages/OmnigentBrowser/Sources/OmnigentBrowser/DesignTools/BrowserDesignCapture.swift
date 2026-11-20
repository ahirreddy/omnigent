internal import CoreGraphics
internal import Foundation
internal import ImageIO

/// The tools' screenshots, from a snapshot of the page alone: Annotate's of the element it
/// picked, and Draw's with the marks drawn on.
nonisolated enum BrowserDesignCapture {
  /// The margin round a picked element's screenshot, in CSS pixels.
  static let padding: CGFloat = 8
  /// The largest image a message may carry (the server's limit for images).
  static let maxPNGBytes = 5 * 1024 * 1024

  /// Decodes a PNG snapshot.
  /// - Throws: `BrowserError.snapshotFailed` for data that isn't an image.
  static func image(fromPNG data: Data) throws(BrowserError) -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw .snapshotFailed("The page's snapshot couldn't be read.") }
    return image
  }

  /// The pixels to crop for an element at `rect` (CSS pixels) from an image of `imageSize`
  /// showing a `viewport` (CSS pixels): the element and its margin, inside the image.
  /// - Throws: `BrowserError.snapshotFailed` when none of it is on screen.
  static func elementCrop(_ rect: CGRect, viewport: CGSize, imageSize: CGSize) throws(BrowserError)
    -> CGRect
  {
    let offScreen = BrowserError.snapshotFailed("The element isn't on screen.")
    guard viewport.width > 0, viewport.height > 0, rect.width.isFinite, rect.height.isFinite
    else { throw offScreen }
    let left = max(0, rect.minX - padding)
    let top = max(0, rect.minY - padding)
    let right = min(viewport.width, rect.maxX + padding)
    let bottom = min(viewport.height, rect.maxY + padding)
    guard right - left >= 2, bottom - top >= 2 else { throw offScreen }
    let scaleX = imageSize.width / viewport.width
    let scaleY = imageSize.height / viewport.height
    let pixels = CGRect(
      x: (left * scaleX).rounded(.down), y: (top * scaleY).rounded(.down),
      width: ((right - left) * scaleX).rounded(.up), height: ((bottom - top) * scaleY).rounded(.up))
    let inside = pixels.intersection(CGRect(origin: .zero, size: imageSize))
    guard !inside.isNull, inside.width >= 1, inside.height >= 1 else { throw offScreen }
    return inside
  }

  /// The element's screenshot as PNG.
  /// - Throws: `BrowserError.snapshotFailed` when it is off screen or can't be encoded.
  static func elementPNG(snapshot: CGImage, hit: BrowserDesignHit) throws(BrowserError) -> Data {
    let size = CGSize(width: snapshot.width, height: snapshot.height)
    let crop = try elementCrop(hit.rect, viewport: hit.viewport, imageSize: size)
    guard let cropped = snapshot.cropping(to: crop) else {
      throw .snapshotFailed("The element's screenshot couldn't be cut from the page's.")
    }
    return try pngData(cropped)
  }

  /// The page's snapshot with `marks` (in the overlay's points, over a view of `viewSize`)
  /// drawn on, as PNG.
  /// - Throws: `BrowserError.snapshotFailed` when it can't be drawn or encoded.
  static func drawingPNG(snapshot: CGImage, marks: [BrowserDesignMark], viewSize: CGSize)
    throws(BrowserError) -> Data
  {
    guard viewSize.width > 0, viewSize.height > 0 else {
      throw .snapshotFailed("The page has no size to draw on.")
    }
    let context = try bitmap(width: snapshot.width, height: snapshot.height)
    let size = CGSize(width: snapshot.width, height: snapshot.height)
    context.draw(snapshot, in: CGRect(origin: .zero, size: size))
    // Top-left origin in the overlay's points, as the live drawing.
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: size.width / viewSize.width, y: -size.height / viewSize.height)
    BrowserDesignMarkDrawing.draw(marks, in: context)
    guard let image = context.makeImage() else {
      throw .snapshotFailed("The drawing couldn't be made into an image.")
    }
    return try pngData(image)
  }

  /// `image` as PNG, halved until it fits ``maxPNGBytes``.
  /// - Throws: `BrowserError.snapshotFailed` when it can't be encoded, or is still too large.
  static func pngData(_ image: CGImage, limit: Int = maxPNGBytes) throws(BrowserError) -> Data {
    var current = image
    while true {
      let data = try encodePNG(current)
      if data.count <= limit { return data }
      guard current.width > 64, current.height > 64 else {
        throw .snapshotFailed("The screenshot is too large to send.")
      }
      current = try halved(current)
    }
  }

  private static func encodePNG(_ image: CGImage) throws(BrowserError) -> Data {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    else { throw .snapshotFailed("PNG encoding is unavailable.") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw .snapshotFailed("PNG encoding failed.")
    }
    return data as Data
  }

  private static func halved(_ image: CGImage) throws(BrowserError) -> CGImage {
    let width = image.width / 2
    let height = image.height / 2
    let context = try bitmap(width: width, height: height)
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let smaller = context.makeImage() else {
      throw .snapshotFailed("The screenshot couldn't be made smaller.")
    }
    return smaller
  }

  private static func bitmap(width: Int, height: Int) throws(BrowserError) -> CGContext {
    guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw .snapshotFailed("The screenshot couldn't be drawn.") }
    return context
  }
}
