public import Foundation
public import OmnigentCoreFFI

/// `HttpTransport` host implementation backed by `URLSession`.
///
/// Per the core contract it never follows redirects (a 3xx is returned as-is), adds no cookies or
/// caching of its own, and returns every HTTP status as a response rather than an error.
public final class URLSessionHttpTransport: HttpTransport, Sendable {
  private let session: URLSession
  private let heldSession: URLSession
  private let redirectPolicy = RefuseRedirects()

  /// How long a request the server holds for the user may wait for its reply: the server's
  /// longest approval wait, one day.
  static let heldRequestTimeout: TimeInterval = 86_400

  /// Creates a transport.
  /// - Parameter session: Session used for every request. Defaults to
  ///   ``makeDefaultSession()``, with ``makeHeldSession()`` for the requests the server may hold
  ///   for the user (``isHeldForTheUser(_:)``).
  public init(session: URLSession? = nil) {
    self.session = session ?? Self.makeDefaultSession()
    heldSession = session ?? Self.makeHeldSession()
  }

  /// The default session, except that it waits up to ``heldRequestTimeout`` for a reply.
  /// - Returns: A new `URLSession`.
  public static func makeHeldSession() -> URLSession {
    makeDefaultSession(timeout: heldRequestTimeout)
  }

  /// Whether the server may hold `request` until the user answers: a session event, such as a
  /// message a policy asks the user about before the agent may read it. Closing it early would
  /// drop the message.
  /// - Parameter request: The request built by the core.
  /// - Returns: `true` for a `POST` to a session's events.
  static func isHeldForTheUser(_ request: HttpRequest) -> Bool {
    guard request.method == "POST", let path = URLComponents(string: request.url)?.path else {
      return false
    }
    // `/v1/sessions/{id}/events`, under any mount.
    let tail = Array(path.split(separator: "/").suffix(4))
    return tail.count == 4 && tail[0] == "v1" && tail[1] == "sessions" && tail[3] == "events"
  }

  /// An ephemeral session with cookies and caching disabled.
  /// - Parameter timeout: How long a request may wait for more data.
  /// - Returns: A new `URLSession`.
  public static func makeDefaultSession(timeout: TimeInterval = 30) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.waitsForConnectivity = false
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
  }

  /// Sends `request` and returns the response, whatever its status.
  /// - Parameter request: The request built by the core.
  /// - Returns: The HTTP response.
  /// - Throws: `TransportError` when no HTTP response was received.
  public func send(request: HttpRequest) async throws(TransportError) -> HttpResponse {
    var urlRequest = try Self.makeURLRequest(request)
    let held = Self.isHeldForTheUser(request)
    if held { urlRequest.timeoutInterval = Self.heldRequestTimeout }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await (held ? heldSession : session).data(
        for: urlRequest, delegate: redirectPolicy)
    } catch {
      throw TransportErrorMapping.map(error)
    }
    guard let http = response as? HTTPURLResponse else {
      throw .Other(
        message: "Expected an HTTP response from \(request.url), got \(type(of: response))")
    }
    logRefusedRequest(urlRequest, status: http.statusCode, body: data)
    return HttpResponse(
      status: UInt16(truncatingIfNeeded: http.statusCode), headers: Self.headers(from: http),
      body: data)
  }

  static func makeURLRequest(_ request: HttpRequest) throws(TransportError) -> URLRequest {
    guard let url = URL(string: request.url), url.scheme != nil else {
      throw .Other(message: "Invalid request URL: \(request.url)")
    }
    var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    urlRequest.httpShouldHandleCookies = false
    urlRequest.httpMethod = request.method
    for header in request.headers {
      urlRequest.addValue(header.value, forHTTPHeaderField: header.name)
    }
    urlRequest.httpBody = request.body
    return urlRequest
  }

  static func headers(from response: HTTPURLResponse) -> [HttpHeader] {
    response.allHeaderFields
      .map { key, value in
        HttpHeader(name: String(describing: key), value: String(describing: value))
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }
}

/// Uses the completion-handler variant: the `async` variant of this `@objc` requirement crashes
/// Swift 6.4.2 SILGen (`emitNativeToForeignThunk`) with NonisolatedNonsendingByDefault enabled.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
