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

  /// The browser engines this edition ships.
  /// - Returns: A provider offering Chromium and WebKit, or WebKit only.
  static func makeBrowserProvider() -> DefaultBrowserEngineProvider {
    makeBrowserEngines(agentDevTools: false).provider
  }

  /// The browser engines this edition ships, with Chromium's DevTools port open on loopback
  /// for agents when `agentDevTools` is on (the Developer ID edition only).
  /// - Parameter agentDevTools: The user's *Let agents use this browser* setting.
  /// - Returns: The provider, the port when it is open, and why it is closed when opening failed.
  static func makeBrowserEngines(agentDevTools: Bool) -> BrowserEngines {
    #if OMNIGENT_CHROMIUM
      var configuration = ChromiumConfiguration.standard()
      var failure: BrowserError?
      if agentDevTools {
        do {
          configuration = try configuration.withAgentDevTools()
        } catch {
          failure = error
        }
      }
      return BrowserEngines(
        provider: DefaultBrowserEngineProvider.withChromium(configuration: configuration),
        agentDevToolsPort: configuration.agentDevToolsPort, failure: failure)
    #else
      return BrowserEngines(provider: DefaultBrowserEngineProvider(), agentDevToolsPort: nil)
    #endif
  }
}

/// An edition's browser engines and Chromium's DevTools port for agents.
struct BrowserEngines {
  /// The engines.
  let provider: DefaultBrowserEngineProvider
  /// Chromium's loopback DevTools port; `nil` when closed.
  let agentDevToolsPort: Int?
  /// Why the port is closed although agent browsing is on.
  var failure: BrowserError?
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
