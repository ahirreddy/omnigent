public import Foundation

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

/// Failures of the platform shims.
public enum PlatformError: Error, Equatable, CustomStringConvertible {
  /// The system refused to open the URL.
  case cannotOpenURL(URL)

  /// A user-facing description.
  public var description: String {
    switch self {
    case .cannotOpenURL(let url): "The system could not open \(url.absoluteString)"
    }
  }
}

/// The general system pasteboard.
@MainActor
public enum Pasteboard {
  /// Replaces the pasteboard contents with `string`.
  /// - Parameter string: The text to copy.
  public static func copy(_ string: String) {
    #if os(iOS)
      UIPasteboard.general.string = string
    #elseif os(macOS)
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(string, forType: .string)
    #endif
  }

  /// The pasteboard's current text, if any.
  public static var string: String? {
    #if os(iOS)
      UIPasteboard.general.string
    #elseif os(macOS)
      NSPasteboard.general.string(forType: .string)
    #endif
  }
}

/// Opens URLs in the system's default handler (browser, Mail, another app).
@MainActor
public enum ExternalURLOpener {
  /// Opens `url` outside the app.
  /// - Parameter url: The URL to open.
  /// - Throws: ``PlatformError/cannotOpenURL(_:)`` when no handler accepted it.
  public static func open(_ url: URL) async throws(PlatformError) {
    #if os(iOS)
      let opened = await UIApplication.shared.open(url)
    #elseif os(macOS)
      let opened = NSWorkspace.shared.open(url)
    #endif
    guard opened else { throw .cannotOpenURL(url) }
  }
}
