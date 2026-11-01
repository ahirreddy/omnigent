/// The web engines the embedded browser can host.
///
/// Raw values are persisted, so they must stay stable.
nonisolated public enum BrowserEngineKind: String, CaseIterable, Codable, Hashable, Sendable,
  Identifiable
{
  /// Chromium via CEF. macOS only.
  case chromium
  /// The web view the OS provides. Currently WKWebView on macOS and iOS.
  case system

  /// Stable identifier for SwiftUI lists and pickers.
  public var id: String { rawValue }

  /// User-facing engine name.
  public var displayName: String {
    switch self {
    case .chromium: "Chromium"
    case .system: "System (WebKit)"
    }
  }

  /// Whether this platform can ever host the engine. App Store rules limit iOS and iPadOS to
  /// WebKit, so Chromium is macOS-only.
  public var isSupportedOnThisPlatform: Bool {
    switch self {
    case .system:
      return true
    case .chromium:
      #if os(macOS)
        return true
      #else
        return false
      #endif
    }
  }

  /// Engines the user may choose on this platform, in display order.
  public static var supportedOnThisPlatform: [Self] {
    allCases.filter(\.isSupportedOnThisPlatform)
  }
}
