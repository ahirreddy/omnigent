import CoreGraphics
import SwiftUI
import Testing

@testable import OmnigentUIComponents

@MainActor
struct TabThumbnailsTests {
  @Test func keepsTheLatestPicturePerTab() throws {
    let thumbnails = TabThumbnails(capacity: 3)
    let first = try picture(width: 4)
    let second = try picture(width: 8)
    thumbnails.store(first, for: "a")
    thumbnails.store(second, for: "a")
    #expect(thumbnails.image(for: "a")?.width == 8)
    #expect(thumbnails.image(for: "b") == nil)
  }

  @Test func dropsTheLeastRecentlyCapturedPastCapacity() throws {
    let thumbnails = TabThumbnails(capacity: 2)
    thumbnails.store(try picture(width: 1), for: "a")
    thumbnails.store(try picture(width: 1), for: "b")
    // Capturing "a" again makes "b" the oldest.
    thumbnails.store(try picture(width: 1), for: "a")
    thumbnails.store(try picture(width: 1), for: "c")
    #expect(thumbnails.image(for: "a") != nil)
    #expect(thumbnails.image(for: "b") == nil)
    #expect(thumbnails.image(for: "c") != nil)
  }

  @Test func forgetsAClosedTab() throws {
    let thumbnails = TabThumbnails(capacity: 2)
    thumbnails.store(try picture(width: 1), for: "a")
    thumbnails.remove("a")
    thumbnails.store(try picture(width: 1), for: "b")
    thumbnails.store(try picture(width: 1), for: "c")
    #expect(thumbnails.image(for: "a") == nil)
    #expect(thumbnails.image(for: "b") != nil)
  }

  @Test func scaleKeepsTheLongestSideWithinBounds() {
    let thumbnails = TabThumbnails(longestSide: 1_000)
    // An iPhone screen: 874 pt tall draws at about 1.14x, not the screen's 3x.
    let phone = thumbnails.scale(for: CGSize(width: 402, height: 874), screenScale: 3)
    #expect(abs(phone * 874 - 1_000) < 0.5)
    // A small window never draws above the screen's scale.
    #expect(thumbnails.scale(for: CGSize(width: 200, height: 300), screenScale: 2) == 2)
    #expect(thumbnails.scale(for: .zero, screenScale: 2) == 1)
  }

  private func picture(width: Int) throws -> CGImage {
    let renderer = ImageRenderer(content: Color.gray.frame(width: CGFloat(width), height: 1))
    renderer.scale = 1
    return try #require(renderer.cgImage)
  }
}
