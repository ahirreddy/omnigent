public import Foundation
public import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// The `#if os()` shims the workspace views need: the pasteboard and image decoding.
public enum WorkspacePlatform {
  /// Puts `text` on the general pasteboard.
  static func copy(_ text: String) {
    #if os(macOS)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #else
      UIPasteboard.general.string = text
    #endif
  }

  /// The decoded image and its pixel size, or `nil` when the platform cannot decode `data`.
  public static func image(from data: Data) -> (image: Image, size: CGSize)? {
    #if os(macOS)
      guard let image = NSImage(data: data) else { return nil }
      let pixels = image.representations.first.map {
        CGSize(width: $0.pixelsWide, height: $0.pixelsHigh)
      }
      return (Image(nsImage: image), pixels ?? image.size)
    #else
      guard let image = UIImage(data: data) else { return nil }
      let size = CGSize(
        width: image.size.width * image.scale, height: image.size.height * image.scale)
      return (Image(uiImage: image), size)
    #endif
  }

  /// The name of the system file manager, for "Reveal in ...".
  static var fileManagerName: String {
    #if os(macOS)
      "Finder"
    #else
      "Files"
    #endif
  }
}
