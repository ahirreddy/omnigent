import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import OmnigentUIComponents

#if os(macOS)
  import AppKit
#endif

@Suite("Pasted images become image attachments")
struct PastedImageTests {
  private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])

  /// A one-pixel PNG.
  private static let pixel = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
  )

  /// The one-pixel image encoded as `type`.
  private static func encodedImage(_ type: UTType) throws -> Data {
    let png = try #require(pixel)
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let output = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
  }

  /// A provider offering `types` in order; those in `failing` fail as a pasteboard does when it
  /// lists a representation it cannot give.
  private static func provider(
    _ types: [UTType], failing: Set<UTType>, data: @escaping @Sendable (UTType) -> Data
  ) -> NSItemProvider {
    let provider = NSItemProvider()
    for type in types {
      provider.registerDataRepresentation(for: type, visibility: .all) { completion in
        if failing.contains(type) {
          completion(nil, CocoaError(.fileReadUnknown))
        } else {
          completion(data(type), nil)
        }
        return nil
      }
    }
    return provider
  }

  @Test("Formats the server reads come first, then the others, each in the provider's order")
  func readingOrder() {
    let order = PastedImage.readingOrder([.tiff, .plainText, .jpeg, .heic, .png])
    #expect(order == [.jpeg, .png, .tiff, .heic])
  }

  @Test("PNG, JPEG, GIF and WebP pass through; TIFF and HEIC become PNG")
  func normalization() throws {
    let png = try Self.encodedImage(.png)
    let kept = try PastedImage.normalized(png, type: .png)
    #expect(kept.data == png)
    #expect(kept.type == .png)
    #expect(kept.fileName("Pasted item 1") == "Pasted item 1.png")

    for type in [UTType.tiff, .heic] {
      let converted = try PastedImage.normalized(try Self.encodedImage(type), type: type)
      #expect(converted.type == .png)
      #expect(converted.data.prefix(4) == Self.pngSignature)
      let source = try #require(CGImageSourceCreateWithData(converted.data as CFData, nil))
      let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
      #expect(image.width == 1 && image.height == 1)
    }
  }

  @Test("Bytes that are not an image are an error, not an attachment")
  func undecodable() {
    #expect(throws: PastedImage.ConversionError.self) {
      try PastedImage.normalized(Data("not an image".utf8), type: .tiff)
    }
  }

  @Test("A listed PNG that fails to load falls back to the TIFF, converted to PNG")
  func failingRepresentationFallsBack() async throws {
    let tiff = try Self.encodedImage(.tiff)
    let provider = Self.provider([.png, .tiff], failing: [.png]) { _ in tiff }
    let input = try await ItemProviderLoader.load(provider, index: 0)
    guard case .data(let data, let name, let type) = input else {
      Issue.record("expected image data, got \(input)")
      return
    }
    #expect(type == .png)
    #expect(name == "Pasted item 1.png")
    #expect(data.prefix(4) == Self.pngSignature)
  }

  #if os(macOS)
    /// A private pasteboard holding one item with `contents`, so the user's clipboard is untouched.
    private static func pasteboard(_ contents: [NSPasteboard.PasteboardType: Data])
      -> NSPasteboard
    {
      let pasteboard = NSPasteboard(name: .init("omnigent-test-\(UUID().uuidString)"))
      pasteboard.clearContents()
      let item = NSPasteboardItem()
      for (type, data) in contents { item.setData(data, forType: type) }
      pasteboard.writeObjects([item])
      return pasteboard
    }

    @Test("⌘V attaches a screenshot or a Safari image (with its address), not copied text")
    func macPasteboardDecision() throws {
      let png = try Self.encodedImage(.png)
      let tiff = try Self.encodedImage(.tiff)
      let link = Data("https://example.com/cat.tiff".utf8)
      let cases: [([NSPasteboard.PasteboardType: Data], Bool)] = [
        ([.png: png], true),
        ([.tiff: tiff, .string: link], true),
        ([.string: Data("some words".utf8), .png: png], false),
        ([.string: link], false),
      ]
      for (contents, attaches) in cases {
        let pasteboard = Self.pasteboard(contents)
        defer { pasteboard.releaseGlobally() }
        #expect(PasteboardImages.shouldAttach(pasteboard) == attaches, "\(contents.keys)")
      }
    }

    @Test("A Safari TIFF on the Mac pasteboard attaches as PNG")
    func macPasteboardTIFF() async throws {
      let pasteboard = Self.pasteboard([
        .tiff: try Self.encodedImage(.tiff), .string: Data("https://example.com/a".utf8),
      ])
      defer { pasteboard.releaseGlobally() }
      let providers = PasteboardImages.providers(pasteboard)
      #expect(providers.count == 1)
      let input = try await ItemProviderLoader.load(try #require(providers.first), index: 0)
      guard case .data(let data, let name, let type) = input else {
        Issue.record("expected image data, got \(input)")
        return
      }
      #expect(type == .png && name == "Pasted item 1.png")
      #expect(data.prefix(4) == Self.pngSignature)
    }
  #endif

  @Test("When no representation loads, the error names the item and each failure")
  func everyRepresentationFails() async {
    let provider = Self.provider([.png, .jpeg], failing: [.png, .jpeg]) { _ in Data() }
    do {
      let input = try await ItemProviderLoader.load(provider, index: 2)
      Issue.record("expected a failure, got \(input)")
    } catch {
      let message = error.localizedDescription
      #expect(message.hasPrefix("Pasted item 3 could not be read as an image"))
      // The PNG, the JPEG, then the image object.
      #expect(message.components(separatedBy: ";").count == 3)
    }
  }
}
