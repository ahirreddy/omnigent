public import Foundation

nonisolated extension DeepLinkRoute {
  /// The in-app route of a link to the web app on `server`
  /// (`http://127.0.0.1:6767/c/<id>?message=<id>`, `/settings/mcp`, `/usage`), so a clicked
  /// link to the connected server opens in the app instead of the browser. `nil` for another
  /// origin, a path outside the server's mount, invites, and paths the app does not route
  /// (`/v1/…`, `/docs`).
  /// - Parameters:
  ///   - webURL: The clicked link.
  ///   - server: The connected server, including any mount such as `/omnigent`.
  public init?(webURL: URL, server: URL) {
    guard let target = Self.origin(webURL), target == Self.origin(server),
      var components = URLComponents(url: webURL, resolvingAgainstBaseURL: false)
    else { return nil }
    var mount = server.path
    while mount.hasSuffix("/") { mount.removeLast() }
    let path = components.percentEncodedPath
    guard mount.isEmpty || path == mount || path.hasPrefix("\(mount)/") else { return nil }
    components.percentEncodedPath = String(path.dropFirst(mount.count))
    components.scheme = OmnigentDeepLink.scheme
    // The origin was matched above; the link parser only reads the path and query.
    components.host = "localhost"
    components.port = nil
    components.fragment = nil
    guard let link = components.string,
      let route = try? OmnigentDeepLink(parsing: link).route
    else { return nil }
    if case .register = route { return nil }
    self = route
  }

  private static func origin(_ url: URL) -> ServerOrigin? {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
    return try? ServerOrigin(url: url)
  }
}
