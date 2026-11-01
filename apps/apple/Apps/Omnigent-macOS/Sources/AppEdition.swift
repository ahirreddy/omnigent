import OmnigentBrowser

#if OMNIGENT_CHROMIUM
  import OmnigentBrowserChromium
#endif

/// What differs between the two macOS builds. Everything else is shared source.
///
/// - `OmnigentMac` (Developer ID, notarized, no App Sandbox) compiles with `OMNIGENT_CHROMIUM`,
///   links `OmnigentBrowserChromium` and embeds CEF with its helpers.
/// - `OmnigentMacAppStore` (App Sandbox) does not define it, never links CEF, and offers only
///   the system engine.
enum AppEdition: Sendable {
  /// Distributed outside the Mac App Store.
  case developerID
  /// Distributed through the Mac App Store.
  case appStore

  /// The edition this binary was built as.
  static var current: Self {
    #if OMNIGENT_CHROMIUM
      .developerID
    #else
      .appStore
    #endif
  }

  /// A short name for logs and diagnostics.
  var displayName: String {
    switch self {
    case .developerID: "Developer ID"
    case .appStore: "Mac App Store"
    }
  }

  /// The browser engines this edition ships.
  /// - Returns: A provider offering Chromium and WebKit, or WebKit only.
  static func makeBrowserProvider() -> DefaultBrowserEngineProvider {
    #if OMNIGENT_CHROMIUM
      DefaultBrowserEngineProvider.withChromium()
    #else
      DefaultBrowserEngineProvider()
    #endif
  }
}
