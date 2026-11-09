import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import OmnigentBrowser

/// Answers one address with a set status, so a test needs no server.
final class StatusURLProtocol: URLProtocol {
  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let url = request.url ?? URL(filePath: "/")
    let status = Int(url.lastPathComponent) ?? 200
    if let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: nil, headerFields: nil)
    {
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

/// PNG bytes for a square of `size`.
func squarePNG(size: Int) throws -> Data {
  let representation = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0))
  return try #require(representation.representation(using: .png, properties: [:]))
}

@Suite("Page icons")
struct FaviconTests {
  private func pixelWidth(of favicon: BrowserFavicon) throws -> Int {
    let source = try #require(CGImageSourceCreateWithData(favicon.pngData as CFData, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)).width
  }

  /// One file with both sizes, as a multi-size .ico has.
  private func twoSizeImage() throws -> Data {
    let output = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(
        output as CFMutableData, UTType.tiff.identifier as CFString, 2, nil))
    for size in [16, 128] {
      let source = try #require(
        CGImageSourceCreateWithData(try squarePNG(size: size) as CFData, nil))
      let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
      CGImageDestinationAddImage(destination, image, nil)
    }
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
  }

  @Test("any image comes out at the size the tab strip draws")
  func normalizes() throws {
    let large = try BrowserFavicon.normalized(try squarePNG(size: 256))
    #expect(try pixelWidth(of: large) == 32)
    let requested = try BrowserFavicon.normalized(try squarePNG(size: 8), size: 16)
    #expect(try pixelWidth(of: requested) == 16)
    let several = try BrowserFavicon.normalized(try twoSizeImage())
    #expect(try pixelWidth(of: several) == 32)
  }

  @Test("what can't be read as an image says so")
  func unreadable() throws {
    #expect(throws: BrowserError.self) {
      try BrowserFavicon.normalized(Data("<svg></svg>".utf8))
    }
    #expect(throws: BrowserError.snapshotFailed("The icon could not be decoded.")) {
      try BrowserFavicon.normalized(try squarePNG(size: 8), size: 0)
    }
  }
}

@MainActor
@Suite("Page icon loading", .serialized)
struct FaviconLoaderTests {
  private func iconFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "favicon-\(UUID().uuidString).png")
    try data.write(to: url)
    return url
  }

  @Test("an icon is fetched once and kept for the session")
  func cachesIcons() async throws {
    let loader = BrowserFaviconLoader()
    let file = try iconFile(try squarePNG(size: 32))
    async let first = loader.favicon(at: file)
    async let second = loader.favicon(at: file)
    let (one, two) = try await (first, second)
    #expect(one.pngData == two.pngData)
    try FileManager.default.removeItem(at: file)
    let cached = try await loader.favicon(at: file)
    #expect(cached.pngData == one.pngData)
  }

  @Test("a missing icon, an image too large and a damaged one each report a failure")
  func failures() async throws {
    let loader = BrowserFaviconLoader()
    let missing = FileManager.default.temporaryDirectory.appending(path: "no-such-\(UUID()).png")
    await #expect(throws: BrowserError.self) { try await loader.favicon(at: missing) }
    let big = try iconFile(Data(repeating: 0, count: 1_000_001))
    defer { try? FileManager.default.removeItem(at: big) }
    await #expect(throws: BrowserError.snapshotFailed("The icon is larger than 1 MB.")) {
      try await loader.favicon(at: big)
    }
    let damaged = try iconFile(Data("not an image".utf8))
    defer { try? FileManager.default.removeItem(at: damaged) }
    await #expect(throws: BrowserError.self) { try await loader.favicon(at: damaged) }
  }

  @Test("a server's error page isn't taken for an icon")
  func serverError() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StatusURLProtocol.self]
    let loader = BrowserFaviconLoader(session: URLSession(configuration: configuration))
    let url = try testURL("https://a.example/404")
    await #expect(
      throws: BrowserError.navigationFailed(
        url: url, code: 404, message: "The icon request failed.")
    ) { try await loader.favicon(at: url) }
  }
}
