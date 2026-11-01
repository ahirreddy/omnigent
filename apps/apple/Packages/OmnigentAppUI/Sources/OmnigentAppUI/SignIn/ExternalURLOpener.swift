public import Foundation

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Opens a URL in the user's default browser, outside the app.
public struct ExternalURLOpener {
  /// Opens `url`; returns whether the system accepted it.
  public var open: @MainActor (URL) async -> Bool

  /// Creates an opener.
  /// - Parameter open: Opens a URL; returns whether the system accepted it.
  public init(open: @escaping @MainActor (URL) async -> Bool) {
    self.open = open
  }

  /// The system browser.
  public static let system = Self { url in
    #if os(macOS)
      NSWorkspace.shared.open(url)
    #else
      await UIApplication.shared.open(url)
    #endif
  }
}
