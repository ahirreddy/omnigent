public import Foundation
import OmnigentCoreFFI
public import OmnigentDeepLinks
import OmnigentStores

/// What a single-server scene (an iPhone or iPad window) does with an `omnigent://` link. A
/// scene shows one server at a time, so a link to another server moves the scene there.
public enum SceneLinkPlan: Equatable, Sendable {
  /// Apply the route now: the scene is on the link's server, or the route (an invite) applies
  /// while it signs in.
  case apply(OmnigentDeepLinks.DeepLinkRoute)
  /// The scene is connecting to the link's server: apply the route once it is signed in.
  case applyWhenReady(OmnigentDeepLinks.DeepLinkRoute)
  /// Move the scene to a server the user connected to before, then apply the route.
  case switchServer(URL, OmnigentDeepLinks.DeepLinkRoute)
  /// The server was never used: ask before connecting to it.
  case confirm

  /// Plans a link with the desktop's routing rules, the scene being its one window.
  /// - Parameters:
  ///   - link: The parsed link.
  ///   - sceneServer: The server the scene is connected or connecting to.
  ///   - isReady: Whether the scene is signed in to `sceneServer`.
  ///   - knownServers: Servers the user connected to before, most recent first.
  /// - Returns: The plan.
  public static func plan(
    _ link: OmnigentDeepLink, sceneServer: URL?, isReady: Bool, knownServers: [URL]
  ) -> Self {
    var known: [ServerOrigin: URL] = [:]
    for url in knownServers {
      // A recent entry that is not an http(s) server cannot match a link; it is skipped.
      if let origin = ServerOrigin(validURL: url), known[origin] == nil { known[origin] = url }
    }
    let windows = sceneServer.flatMap(ServerOrigin.init(validURL:)).map {
      [WindowRoutingSnapshot(id: 0, origin: $0, isReady: isReady)]
    }
    let strategy = DeepLinkRouting.strategy(
      target: link.origin, windows: windows ?? [], knownOrigins: Set(known.keys), focused: 0)
    switch strategy {
    case .navigate:
      return .apply(link.route)
    case .navigateWhenReady:
      return link.route.appliesBeforeSignIn ? .apply(link.route) : .applyWhenReady(link.route)
    case .openKnownServer:
      guard let url = known[link.origin] else { return .confirm }
      return .switchServer(url, link.route)
    case .requireConsent:
      return .confirm
    }
  }

  /// The invite page on `server` that Create Account opens with, `…/register?invite=<token>`.
  /// - Parameters:
  ///   - server: The server, including any workspace mount.
  ///   - invite: The invite token.
  /// - Returns: The link, or `nil` when `server` is not a URL with a path.
  public static func inviteLink(server: URL, invite: String) -> String? {
    guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
      return nil
    }
    while components.path.hasSuffix("/") { components.path.removeLast() }
    components.path += "/register"
    components.queryItems = [URLQueryItem(name: "invite", value: invite)]
    return components.string
  }
}

extension ServerOrigin {
  /// The origin of an http(s) server URL, or `nil` for anything else.
  init?(validURL url: URL) {
    do {
      try self.init(url: url)
    } catch {
      return nil
    }
  }
}

extension ServerSession {
  /// The server the session is connected, connecting or signing in to; `nil` while it shows the
  /// server list.
  public var targetURL: URL? {
    let url: String? =
      switch connection.phase {
      case .disconnected, .failed: nil
      case .discovering(let url): url
      case .signInRequired(let url, _, _, _, _), .signingIn(let url),
        .awaitingBrowserLogin(let url, _), .connecting(let url):
        url
      case .connected(let server): server.baseUrl
      }
    return url.flatMap(URL.init(string:))
  }

  /// Two server URLs name the same server, ignoring case and a trailing slash.
  /// - Parameters:
  ///   - lhs: A server URL.
  ///   - rhs: Another.
  /// - Returns: Whether they match; never for a missing URL.
  public nonisolated static func sameServer(_ lhs: URL?, _ rhs: URL?) -> Bool {
    func key(_ url: URL?) -> String? {
      guard var text = url?.absoluteString.lowercased() else { return nil }
      while text.hasSuffix("/") { text.removeLast() }
      return text
    }
    guard let left = key(lhs) else { return false }
    return left == key(rhs)
  }
}
