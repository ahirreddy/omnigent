import OmnigentBrowser
import OmnigentDesktop

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

  /// The browser engines this edition ships. Chromium gets agents' DevTools pipe; nothing
  /// listens for agents until one of the owner's sessions asks.
  /// - Returns: A provider offering Chromium and WebKit, or WebKit only.
  static func makeBrowserProvider() -> DefaultBrowserEngineProvider {
    #if OMNIGENT_CHROMIUM
      DefaultBrowserEngineProvider.withChromium(
        configuration: ChromiumConfiguration.standard().withAgentDevTools())
    #else
      DefaultBrowserEngineProvider()
    #endif
  }

  /// The engine agents' DevTools proxies reach, starting it if needed; `nil` in the App Store
  /// edition, which has no Chromium.
  /// - Parameter provider: The edition's engines.
  /// - Returns: The gate.
  /// - Throws: When Chromium cannot start.
  static func agentDevToolsGate(_ provider: any BrowserEngineProvider)
    throws(BrowserError) -> (any BrowserAgentDevToolsGate)?
  {
    #if OMNIGENT_CHROMIUM
      try provider.engine(for: .chromium) as? any BrowserAgentDevToolsGate
    #else
      nil
    #endif
  }
}

extension AppEdition {
  /// Whether this edition may run the `omnigent` CLI as a local server: the Developer ID edition
  /// can, the App Store edition runs in App Sandbox and cannot.
  var localServerCapability: LocalServerCapability {
    switch self {
    case .developerID: .available
    case .appStore: .unavailable(.appSandbox)
    }
  }
}
