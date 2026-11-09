internal import CoreGraphics
public import Foundation
internal import ImageIO
public import SwiftUI
internal import UniformTypeIdentifiers

/// A page icon, normalized to a 32-pixel PNG.
nonisolated public struct BrowserFavicon: Hashable, Sendable {
  /// The PNG bytes.
  public let pngData: Data

  /// Wraps PNG data.
  public init(pngData: Data) {
    self.pngData = pngData
  }

  /// The icon as a SwiftUI image, or nil when the data does not decode.
  @MainActor public var image: Image? {
    #if os(macOS)
      NSImage(data: pngData).map { Image(nsImage: $0) }
    #else
      UIImage(data: pngData).map { Image(uiImage: $0) }
    #endif
  }

  /// Decodes any ImageIO format (PNG, ICO, JPEG, GIF, WebP) and scales the largest frame to
  /// `size` pixels square.
  public static func normalized(_ data: Data, size: Int = 32) throws(BrowserError) -> Self {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else {
      throw .snapshotFailed(
        "The icon is not an image ImageIO can read (SVG icons are not supported).")
    }
    var best = 0
    var bestWidth = 0
    for index in 0..<CGImageSourceGetCount(source) {
      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
      let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
      if width > bestWidth {
        best = index
        bestWidth = width
      }
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, best, nil),
      let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      throw .snapshotFailed("The icon could not be decoded.")
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let output = NSMutableData()
    guard let scaled = context.makeImage(),
      let destination = CGImageDestinationCreateWithData(
        output as CFMutableData, UTType.png.identifier as CFString, 1, nil)
    else {
      throw .snapshotFailed("The icon could not be scaled.")
    }
    CGImageDestinationAddImage(destination, scaled, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw .snapshotFailed("The icon could not be encoded.")
    }
    return Self(pngData: output as Data)
  }
}

/// Fetches and caches page icons. Requests carry no cookies (an ephemeral session), so loading
/// an icon never touches any profile's storage.
public final class BrowserFaviconLoader {
  private var cache: [URL: BrowserFavicon] = [:]
  private var inFlight: [URL: Task<Result<BrowserFavicon, BrowserError>, Never>] = [:]
  private let session: URLSession

  /// Creates a loader.
  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.httpCookieStorage = nil
    session = URLSession(configuration: configuration)
  }

  /// A loader fetching through `session`.
  init(session: URLSession) {
    self.session = session
  }

  /// The icon at `url`, fetched once and cached for the session.
  public func favicon(at url: URL) async throws(BrowserError) -> BrowserFavicon {
    if let cached = cache[url] { return cached }
    let task = inFlight[url] ?? Task { [session] in await Self.fetch(url, session: session) }
    inFlight[url] = task
    defer { inFlight[url] = nil }
    let favicon = try await task.value.get()
    cache[url] = favicon
    return favicon
  }

  private nonisolated static func fetch(_ url: URL, session: URLSession) async
    -> Result<BrowserFavicon, BrowserError>
  {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(from: url)
    } catch {
      return .failure(
        .navigationFailed(
          url: url, code: (error as NSError).code, message: error.localizedDescription))
    }
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      return .failure(
        .navigationFailed(url: url, code: http.statusCode, message: "The icon request failed."))
    }
    guard data.count <= 1_000_000 else {
      return .failure(.snapshotFailed("The icon is larger than 1 MB."))
    }
    do throws(BrowserError) {
      return .success(try BrowserFavicon.normalized(data))
    } catch {
      return .failure(error)
    }
  }
}
