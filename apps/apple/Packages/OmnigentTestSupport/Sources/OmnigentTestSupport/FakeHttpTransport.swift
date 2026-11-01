import Foundation
public import OmnigentCoreFFI
import Synchronization

/// Scriptable `HttpTransport` that records every request and answers from a handler.
public final class FakeHttpTransport: HttpTransport, Sendable {
  /// Produces the response for one request.
  public typealias Handler = @Sendable (HttpRequest) async throws(TransportError) -> HttpResponse

  private let handler: Handler
  private let recorded = Mutex<[HttpRequest]>([])

  /// Creates a transport that answers every request with `handler`.
  /// - Parameter handler: Called once per request, after the request is recorded.
  public init(handler: @escaping Handler) {
    self.handler = handler
  }

  /// Serves fixed responses keyed by URL path; any other path is answered with 404.
  /// - Parameter routes: Responses keyed by URL path, for example `/.well-known/omnigent.json`.
  public convenience init(routes: [String: HttpResponse]) {
    self.init { request throws(TransportError) in
      guard let path = URLComponents(string: request.url)?.path else {
        throw .Other(message: "FakeHttpTransport could not parse URL \(request.url)")
      }
      return routes[path]
        ?? HttpResponse(status: 404, headers: [], body: Data("not found".utf8))
    }
  }

  /// Fails every request.
  /// - Parameter error: The error thrown for each request.
  public convenience init(failingWith error: TransportError) {
    self.init { _ throws(TransportError) in throw error }
  }

  /// Every request received so far, in order.
  public var requests: [HttpRequest] {
    recorded.withLock { $0 }
  }

  /// Records `request` and answers it with the handler.
  /// - Parameter request: The request built by the core.
  /// - Returns: The handler's response.
  /// - Throws: Whatever `TransportError` the handler throws.
  public func send(request: HttpRequest) async throws(TransportError) -> HttpResponse {
    recorded.withLock { $0.append(request) }
    return try await handler(request)
  }
}

extension HttpResponse {
  /// A JSON response.
  /// - Parameters:
  ///   - body: UTF-8 JSON text.
  ///   - status: HTTP status code.
  /// - Returns: A response with `Content-Type: application/json`.
  public static func json(_ body: String, status: UInt16 = 200) -> HttpResponse {
    HttpResponse(
      status: status,
      headers: [HttpHeader(name: "Content-Type", value: "application/json")],
      body: Data(body.utf8)
    )
  }
}

/// `/.well-known/omnigent.json` bodies in the shape served by `omnigent/server/app.py`.
public enum ManifestFixtures {
  /// A local server with sign-in disabled.
  public static let localNoAuth = """
    {
      "manifest_version": 1,
      "server_version": "0.42.0",
      "min_desktop_version": null,
      "ui": {"server_picker": "sidebar"},
      "auth": {"mode": "none", "session_cookie": null, "native_redirect_uris": null},
      "server_name": "Local Omnigent"
    }
    """

  /// An OIDC server without a display name.
  public static let oidc = """
    {
      "manifest_version": 1,
      "server_version": "0.42.0",
      "min_desktop_version": null,
      "ui": {"server_picker": "sidebar"},
      "auth": {
        "mode": "oidc",
        "session_cookie": "__Host-ap_session",
        "native_redirect_uris": [
          "ai.omnigent.android:/oauth/callback",
          "ai.omnigent.ios:/oauth/callback"
        ]
      },
      "server_name": null
    }
    """
}
