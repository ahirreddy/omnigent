public import CoreGraphics
public import Foundation
internal import OWLProtocol

/// Where a page asked a new browsing context to open.
nonisolated public enum WebPopupDisposition: Sendable, Hashable {
  /// The same view (rare; usually handled in place).
  case currentTab
  /// A new foreground tab (target=_blank, Command-Shift-click).
  case foregroundTab
  /// A new background tab (Command-click, middle-click).
  case backgroundTab
  /// A popup window (window.open with features).
  case popup
  /// A new window (Shift-click).
  case window

  init(wire value: UInt64) {
    switch OWLDisposition(rawValue: value) {
    case .currentTab: self = .currentTab
    case .backgroundTab: self = .backgroundTab
    case .popup: self = .popup
    case .window: self = .window
    default: self = .foregroundTab
    }
  }
}

/// Which page-opened windows are allowed. The host applies it synchronously.
nonisolated public enum WebPopupPolicy: Sendable, Hashable {
  /// Every window.open and target=_blank opens a view.
  case allow
  /// Only opens that follow a user gesture are allowed. The default.
  case requireUserGesture
  /// Every open is blocked and reported.
  case block

  var wire: OWLPopupPolicy {
    switch self {
    case .allow: .allow
    case .requireUserGesture: .requireGesture
    case .block: .block
    }
  }
}

/// A view the page opened. It shares the opener's profile and, for window.open and
/// target=_blank, keeps `window.opener`.
public struct WebPopup {
  /// The new view. It is live, or about to be; embed it or close it.
  public let webView: WebView
  /// The view that opened it.
  public let opener: WebView
  /// The URL it is loading.
  public let targetURL: URL?
  /// Where the page wanted it.
  public let disposition: WebPopupDisposition
  /// Whether a user gesture opened it.
  public let userGesture: Bool
  /// The `window.open` target name, possibly empty.
  public let frameName: String
  /// The size window.open asked for, in points, when it asked.
  public let requestedSize: CGSize?
}

/// A window the popup policy stopped.
nonisolated public struct WebBlockedPopup: Sendable, Hashable {
  /// The URL the page tried to open.
  public let url: URL?
  /// Where the page wanted it.
  public let disposition: WebPopupDisposition
  /// Whether it followed a user gesture.
  public let userGesture: Bool
  /// Why it was blocked.
  public let reason: String
}

/// Declarative navigation rules a view enforces in the host for every navigation, including
/// redirects and page-initiated ones. They match OmnigentBrowser's `AgentURLRules`.
nonisolated public struct WebNavigationRules: Sendable, Hashable, Codable {
  /// Allowed schemes, lowercase; empty allows all.
  public var schemes: [String]
  /// Host patterns that are allowed; empty allows every host the other rules allow. A pattern
  /// matches the host and its subdomains.
  public var allow: [String]
  /// Host patterns that are always blocked. Deny wins over allow.
  public var deny: [String]
  /// Blocks IP literals outside public unicast space (cloud metadata, RFC 1918, link-local).
  public var blockPrivateAddresses: Bool
  /// Allows loopback hosts even when private addresses are blocked or an allow list is set.
  public var allowLoopback: Bool

  /// Creates rules.
  public init(
    schemes: [String] = ["http", "https"], allow: [String] = [], deny: [String] = [],
    blockPrivateAddresses: Bool = true, allowLoopback: Bool = false
  ) {
    self.schemes = schemes
    self.allow = allow
    self.deny = deny
    self.blockPrivateAddresses = blockPrivateAddresses
    self.allowLoopback = allowLoopback
  }

  var json: String { WireJSON.encode(self) }
}
