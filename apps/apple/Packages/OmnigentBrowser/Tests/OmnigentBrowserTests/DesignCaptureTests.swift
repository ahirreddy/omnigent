import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import OmnigentBrowser

/// A solid image of `width` by `height` pixels.
func solidImage(width: Int, height: Int, gray: CGFloat = 1) throws -> CGImage {
  let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
  let context = try #require(
    CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  return try #require(context.makeImage())
}

/// The red, green and blue of a pixel (0 to 255), counted from the top left.
func pixel(_ image: CGImage, x column: Int, y row: Int) throws -> [Int] {
  let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
  let context = try #require(
    CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.draw(
    image,
    in: CGRect(
      x: -column, y: row - image.height + 1, width: image.width, height: image.height))
  let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
  return (0..<3).map { Int(bytes[$0]) }
}

/// The tools' screenshots: an element cut from the page's, and the page's with marks on.
@Suite("Design tools: screenshots")
struct DesignCaptureTests {
  @Test("an element's crop is its rect and margin, in the snapshot's pixels")
  func elementCrop() throws {
    let viewport = CGSize(width: 800, height: 600)
    let pixels = CGSize(width: 1600, height: 1200)
    let crop = try BrowserDesignCapture.elementCrop(
      CGRect(x: 100, y: 50, width: 200, height: 40), viewport: viewport, imageSize: pixels)
    #expect(crop == CGRect(x: 184, y: 84, width: 432, height: 112))
    // Cut at the viewport's edges.
    let corner = try BrowserDesignCapture.elementCrop(
      CGRect(x: -20, y: 580, width: 60, height: 100), viewport: viewport, imageSize: pixels)
    #expect(corner == CGRect(x: 0, y: 1144, width: 96, height: 56))
  }

  @Test("an element wholly off screen has no crop")
  func offScreen() {
    for rect in [
      CGRect(x: 900, y: 10, width: 50, height: 50), CGRect(x: 10, y: -200, width: 50, height: 50),
    ] {
      #expect(throws: BrowserError.snapshotFailed("The element isn't on screen.")) {
        try BrowserDesignCapture.elementCrop(
          rect, viewport: CGSize(width: 800, height: 600),
          imageSize: CGSize(width: 800, height: 600))
      }
    }
  }

  @Test("an element's screenshot is a PNG of its crop")
  func elementPNG() throws {
    let hit = BrowserDesignHit(
      element: BrowserDesignElement(tag: "p"), rect: CGRect(x: 10, y: 10, width: 20, height: 20),
      viewport: CGSize(width: 100, height: 100), key: "e1")
    let png = try BrowserDesignCapture.elementPNG(
      snapshot: try solidImage(width: 200, height: 200), hit: hit)
    let image = try BrowserDesignCapture.image(fromPNG: png)
    #expect(image.width == 72 && image.height == 72)
    #expect(throws: BrowserError.self) { try BrowserDesignCapture.image(fromPNG: Data("x".utf8)) }
  }

  @Test("marks go on the snapshot where they were drawn over the page")
  func drawing() throws {
    let mark = BrowserDesignMark(
      kind: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 30)], color: .red)
    // A view of 100 by 50 points, captured at twice its size.
    let png = try BrowserDesignCapture.drawingPNG(
      snapshot: try solidImage(width: 200, height: 100), marks: [mark],
      viewSize: CGSize(width: 100, height: 50))
    let image = try BrowserDesignCapture.image(fromPNG: png)
    #expect(image.width == 200 && image.height == 100)
    let marked = try pixel(image, x: 20, y: 40)
    #expect(marked[0] > 200 && marked[1] < 120 && marked[2] < 120)
    #expect(try pixel(image, x: 50, y: 40) == [255, 255, 255])
    #expect(try pixel(image, x: 20, y: 90) == [255, 255, 255])
  }

  @Test("every shape draws, text with its halo")
  func shapes() throws {
    let marks = [
      BrowserDesignMark(
        kind: .pen, points: [CGPoint(x: 5, y: 5), CGPoint(x: 20, y: 5), CGPoint(x: 20, y: 20)],
        color: .black),
      BrowserDesignMark(
        kind: .arrow, points: [CGPoint(x: 30, y: 40), CGPoint(x: 80, y: 40)], color: .blue),
      BrowserDesignMark(kind: .text, points: [CGPoint(x: 10, y: 70)], color: .white, text: "Wider"),
    ]
    let png = try BrowserDesignCapture.drawingPNG(
      snapshot: try solidImage(width: 100, height: 100, gray: 0.5), marks: marks,
      viewSize: CGSize(width: 100, height: 100))
    let image = try BrowserDesignCapture.image(fromPNG: png)
    #expect(try pixel(image, x: 12, y: 5) == [0, 0, 0])
    let arrowBlue = try pixel(image, x: 50, y: 40)[2]
    #expect(arrowBlue > 200)
    let gray = try pixel(image, x: 95, y: 95)[0]
    #expect(abs(gray - 128) <= 1)
  }

  @Test("a screenshot over the limit is halved until it fits, or refused")
  func sizeLimit() throws {
    let image = try solidImage(width: 400, height: 400)
    let full = try BrowserDesignCapture.pngData(image)
    let smaller = try BrowserDesignCapture.pngData(image, limit: full.count - 1)
    #expect(try BrowserDesignCapture.image(fromPNG: smaller).width == 200)
    #expect(throws: BrowserError.snapshotFailed("The screenshot is too large to send.")) {
      try BrowserDesignCapture.pngData(image, limit: 1)
    }
    #expect(throws: BrowserError.self) {
      try BrowserDesignCapture.drawingPNG(snapshot: image, marks: [], viewSize: .zero)
    }
  }
}
