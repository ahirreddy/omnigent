// Pure window selection for deep links and notification taps, ported from
// `chooseDeepLinkStrategy` in web/electron/src/deepLink.js. Covered by DeepLinkRoutingTests.

/// What the router knows about one open window.
nonisolated public struct WindowRoutingSnapshot<WindowID: Hashable & Sendable>: Hashable, Sendable {
  /// The window.
  public var id: WindowID
  /// The server the window is bound to, or `nil` while it shows the connect screen.
  public var origin: ServerOrigin?
  /// Whether the window is connected and can navigate in place. `false` while it signs in or
  /// reconnects.
  public var isReady: Bool

  /// Creates a snapshot.
  /// - Parameters:
  ///   - id: The window.
  ///   - origin: The bound server, if any.
  ///   - isReady: Whether the window can navigate immediately.
  public init(id: WindowID, origin: ServerOrigin?, isReady: Bool) {
    self.id = id
    self.origin = origin
    self.isReady = isReady
  }
}

/// How to open a route on a server.
nonisolated public enum DeepLinkStrategy<WindowID: Hashable & Sendable>: Hashable, Sendable {
  /// Navigate a connected window on the server without disturbing its streams.
  case navigate(WindowID)
  /// The window is bound to the server but still connecting; deliver once it is ready.
  case navigateWhenReady(WindowID)
  /// No window is on the server, but the user connected to it before: open a new window.
  case openKnownServer
  /// The server was never connected: ask before trusting it with a window.
  case requireConsent
}

/// Chooses the window for a deep link.
nonisolated public enum DeepLinkRouting {
  /// Picks a strategy. Prefers a ready window on the server, the focused one among several;
  /// otherwise the focused, then first, connecting window; otherwise a new window on a known
  /// server; otherwise consent. A connecting window is never preferred over a ready one, so a
  /// focused window's sign-in is not interrupted.
  /// - Parameters:
  ///   - target: The server the link names.
  ///   - windows: Open windows in creation order.
  ///   - knownOrigins: Servers the user connected to before (default and recents).
  ///   - focused: The key window, if any.
  /// - Returns: The strategy.
  public static func strategy<WindowID>(
    target: ServerOrigin,
    windows: [WindowRoutingSnapshot<WindowID>],
    knownOrigins: Set<ServerOrigin>,
    focused: WindowID?
  ) -> DeepLinkStrategy<WindowID> {
    let pinned = windows.filter { $0.origin == target }
    let ready = pinned.filter(\.isReady)
    if let pick = ready.first(where: { $0.id == focused }) ?? ready.first {
      return .navigate(pick.id)
    }
    if let pick = pinned.first(where: { $0.id == focused }) ?? pinned.first {
      return .navigateWhenReady(pick.id)
    }
    return knownOrigins.contains(target) ? .openKnownServer : .requireConsent
  }
}
