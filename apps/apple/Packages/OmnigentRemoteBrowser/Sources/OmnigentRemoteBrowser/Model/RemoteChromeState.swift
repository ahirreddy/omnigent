import Foundation
public import OmnigentCoreFFI

/// What the compact address pill shows while it is not being edited: the domain only, as Safari
/// does, with whether the page is secure.
nonisolated public struct RemoteAddressDisplay: Hashable, Sendable {
  /// The domain without `www.`, or the whole address when it has no host; empty for no page.
  public var domain: String
  /// Whether the page was loaded over HTTPS.
  public var isSecure: Bool

  /// Whether there is no page, so the pill offers "Search or enter website".
  public var isEmpty: Bool { domain.isEmpty }

  /// The display for a page address.
  /// - Parameter url: The page's URL as the host reports it.
  public init(url: String) {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "about:blank" else {
      domain = ""
      isSecure = false
      return
    }
    let parsed = URL(string: trimmed)
    isSecure = parsed?.scheme?.lowercased() == "https"
    guard let host = parsed?.host(percentEncoded: false), !host.isEmpty else {
      domain = trimmed
      return
    }
    let lowered = host.lowercased()
    domain = lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
  }
}

/// Safari's collapse on scroll for the remote tab's bars: scrolling the page down collapses the
/// address pill to the domain and hides the bottom toolbar; scrolling up or reaching the top
/// brings them back. Driven by the host's scroll reports, since the page is not a local scroll
/// view.
nonisolated public struct RemoteChromeCollapse: Hashable, Sendable {
  /// How far the page must move in one direction before the bars change, in CSS px.
  public static let threshold = 24.0
  /// The page must be scrolled at least this far before the bars collapse, in CSS px.
  public static let minimumOffset = 44.0

  /// Whether the bars are collapsed.
  public private(set) var isCollapsed = false
  /// The offset where the current movement started.
  private var anchor: Double?
  /// The layout viewport's height in the last report, to tell a resize from a scroll.
  private var viewportHeight: Double?

  /// Expanded.
  public init() {}

  /// Takes a scroll report.
  /// - Parameter metrics: The page's latest scroll metrics.
  /// - Returns: Whether `isCollapsed` changed.
  @discardableResult
  public mutating func scrolled(_ metrics: RemoteScrollMetrics) -> Bool {
    let resized = viewportHeight.map { abs($0 - metrics.viewportHeight) > 0.5 } ?? false
    viewportHeight = metrics.viewportHeight
    // A resize (the bars themselves, the keyboard, rotation) moves the offset without the user
    // scrolling, and at the page's end it would toggle the bars back and forth.
    guard !resized, let start = anchor else {
      anchor = metrics.y
      return false
    }
    if metrics.y <= 1 || metrics.contentHeight <= metrics.viewportHeight + 1 {
      anchor = metrics.y
      return set(collapsed: false)
    }
    let moved = metrics.y - start
    if isCollapsed {
      // Keep the furthest point down, so any scroll back up by the threshold expands.
      if moved > 0 { anchor = metrics.y }
      if moved <= -Self.threshold {
        anchor = metrics.y
        return set(collapsed: false)
      }
    } else {
      if moved < 0 { anchor = metrics.y }
      if moved >= Self.threshold, metrics.y >= Self.minimumOffset {
        anchor = metrics.y
        return set(collapsed: true)
      }
    }
    return false
  }

  /// Brings the bars back (a tap on the collapsed pill, a new page, editing the address).
  /// - Returns: Whether `isCollapsed` changed.
  @discardableResult
  public mutating func expand() -> Bool {
    anchor = nil
    return set(collapsed: false)
  }

  private mutating func set(collapsed: Bool) -> Bool {
    guard isCollapsed != collapsed else { return false }
    isCollapsed = collapsed
    return true
  }
}

/// Who drives the remote page, from this client's side: what the control button offers and the
/// line that says so.
nonisolated public struct RemoteControlStatus: Hashable, Sendable {
  /// The situation.
  public enum Kind: Hashable, Sendable {
    /// Not attached yet, reconnecting, or ended.
    case unavailable
    /// Attached to watch only.
    case viewing
    /// The agent drives; this client may take over.
    case agentBrowsing
    /// The agent asked for the user (a sign-in, a CAPTCHA), with its reason.
    case agentNeedsYou(String)
    /// This client holds control.
    case inControl
    /// The user holds control from another device.
    case otherDevice
  }

  /// The situation.
  public var kind: Kind
  /// Whether Take Over is offered.
  public var canTakeOver: Bool

  /// The status for a snapshot's connection and control.
  /// - Parameters:
  ///   - connection: The connection.
  ///   - control: The control state, once the host reported it.
  public init(connection: RemoteBrowserConnection, control: RemoteBrowserControl?) {
    guard case .attached(let mode) = connection else {
      kind = .unavailable
      canTakeOver = false
      return
    }
    let owner = control?.owner
    let holder = control?.holder
    let holdsControl = owner == .user && holder == .this
    canTakeOver = mode == .control && !holdsControl && holder != .other
    if let handoff = control?.handoff, owner == .agent {
      kind = .agentNeedsYou(handoff.reason)
    } else if mode != .control {
      kind = .viewing
    } else if holdsControl {
      kind = .inControl
    } else if owner == .user {
      kind = .otherDevice
    } else {
      kind = .agentBrowsing
    }
  }

  /// One line for the control strip and menus.
  public var message: String {
    switch kind {
    case .unavailable: "Not connected"
    case .viewing: "Viewing the agent's browser"
    case .agentBrowsing: "Agent is browsing"
    case .agentNeedsYou(let reason): "Agent needs you: \(reason)"
    case .inControl: "You're in control"
    case .otherDevice: "Another device is in control"
    }
  }

  /// Whether the agent is waiting for the user.
  public var needsYou: Bool {
    if case .agentNeedsYou = kind { return true }
    return false
  }
}
