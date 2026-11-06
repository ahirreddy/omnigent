import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

/// Reads pasted or dropped item providers into attachment inputs.
enum ItemProviderLoader {
  enum LoadError: LocalizedError {
    case unsupported(String)
    case empty(String)
    case unreadableImage(String, reasons: [String])

    var errorDescription: String? {
      switch self {
      case .unsupported(let name): "\(name) is not a file or an image."
      case .empty(let name): "\(name) had no data."
      case .unreadableImage(let name, let reasons):
        "\(name) could not be read as an image: \(reasons.joined(separator: "; "))"
      }
    }
  }

  static func load(_ provider: NSItemProvider, index: Int) async throws -> ComposerAttachmentInput {
    let name = provider.suggestedName ?? "Pasted item \(index + 1)"
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      let data = try await data(from: provider, type: .fileURL)
      guard let url = URL(dataRepresentation: data, relativeTo: nil) else {
        throw LoadError.empty(name)
      }
      return .file(url: url)
    }
    let types = PastedImage.readingOrder(provider.registeredContentTypes)
    let canLoadImage = provider.canLoadObject(ofClass: PlatformImage.self)
    guard !types.isEmpty || canLoadImage else { throw LoadError.unsupported(name) }
    // A pasteboard can list a representation its source then fails to give ("Cannot load
    // representation of type public.png"), so each one is tried before the image object.
    var reasons: [String] = []
    for type in types {
      do {
        let image = try PastedImage.normalized(
          try await data(from: provider, type: type), type: type)
        return .data(image.data, suggestedName: image.fileName(name), contentType: image.type)
      } catch {
        reasons.append(error.localizedDescription)
      }
    }
    if canLoadImage {
      do {
        let image = try await image(from: provider)
        return .data(image.data, suggestedName: image.fileName(name), contentType: image.type)
      } catch {
        reasons.append(error.localizedDescription)
      }
    }
    throw LoadError.unreadableImage(name, reasons: reasons)
  }

  private static func data(from provider: NSItemProvider, type: UTType) async throws -> Data {
    let name = provider.suggestedName ?? "The item"
    return try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadDataRepresentation(for: type) { data, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let data {
          continuation.resume(returning: data)
        } else {
          continuation.resume(throwing: LoadError.empty(name))
        }
      }
    }
  }

  /// The provider's image object as PNG, encoded inside the callback so the image never
  /// crosses threads.
  private static func image(from provider: NSItemProvider) async throws -> PastedImage {
    let name = provider.suggestedName ?? "The image"
    return try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadObject(ofClass: PlatformImage.self) { object, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let image = object as? PlatformImage {
          continuation.resume(with: Result { try PastedImage.png(image) })
        } else {
          continuation.resume(throwing: LoadError.empty(name))
        }
      }
    }
  }
}

#if canImport(UIKit)
  typealias PlatformImage = UIImage
#else
  typealias PlatformImage = NSImage
#endif

/// Pasted image bytes in a format the server reads as an image (PNG, JPEG, GIF or WebP); other
/// formats (TIFF, HEIC, BMP...) are re-encoded as PNG.
nonisolated struct PastedImage: Sendable {
  /// The formats sent as they are.
  static let sentAsIs: [UTType] = [.png, .jpeg, .gif, .webP]

  let data: Data
  let type: UTType

  /// The image representations of `registered` to try, the formats sent as they are first,
  /// each group in the provider's order.
  static func readingOrder(_ registered: [UTType]) -> [UTType] {
    let images = registered.filter { $0.conforms(to: .image) }
    let direct = images.filter { isSentAsIs($0) }
    return direct + images.filter { !isSentAsIs($0) }
  }

  /// `data`, said to be `type`, as it is when the server reads that format, else as PNG.
  /// - Throws: ``ConversionError`` when the bytes are not an image ImageIO can decode.
  static func normalized(_ data: Data, type: UTType) throws -> Self {
    if isSentAsIs(type) { return Self(data: data, type: type) }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw ConversionError.undecodable(type.localizedDescription ?? type.identifier) }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else { throw ConversionError.unencodable }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ConversionError.unencodable }
    return Self(data: output as Data, type: .png)
  }

  /// A platform image as PNG.
  /// - Throws: ``ConversionError`` when it has no bitmap to encode.
  static func png(_ image: PlatformImage) throws -> Self {
    #if canImport(UIKit)
      guard let data = image.pngData() else { throw ConversionError.unencodable }
      return Self(data: data, type: .png)
    #else
      guard let tiff = image.tiffRepresentation else { throw ConversionError.unencodable }
      return try normalized(tiff, type: .tiff)
    #endif
  }

  /// The attachment's file name: `base` with this format's extension.
  func fileName(_ base: String) -> String {
    "\(base).\(type.preferredFilenameExtension ?? "png")"
  }

  private static func isSentAsIs(_ type: UTType) -> Bool {
    sentAsIs.contains { type.conforms(to: $0) }
  }

  enum ConversionError: LocalizedError {
    case undecodable(String)
    case unencodable

    var errorDescription: String? {
      switch self {
      case .undecodable(let format): "the \(format) data is not an image this device can decode"
      case .unencodable: "the image could not be converted to PNG"
      }
    }
  }
}
