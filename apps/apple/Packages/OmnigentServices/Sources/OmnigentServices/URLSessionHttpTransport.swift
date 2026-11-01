public import Foundation
public import OmnigentCoreFFI

/// `HttpTransport` host implementation backed by `URLSession`.
///
/// Per the core contract it never follows redirects (a 3xx is returned as-is), adds no cookies or
/// caching of its own, and returns every HTTP status as a response rather than an error.
public final class URLSessionHttpTransport: HttpTransport, Sendable {
  private let session: URLSession
  private let redirectPolicy = RefuseRedirects()

  /// Creates a transport.
  /// - Parameter session: Session used for every request. Defaults to
  ///   ``makeDefaultSession()``.
  public init(session: URLSession = URLSessionHttpTransport.makeDefaultSession()) {
    self.session = session
  }

  /// An ephemeral session with cookies and caching disabled.
  /// - Returns: A new `URLSession`.
  public static func makeDefaultSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
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
    let urlRequest = try Self.makeURLRequest(request)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: urlRequest, delegate: redirectPolicy)
    } catch {
      throw TransportErrorMapping.map(error)
    }
    guard let http = response as? HTTPURLResponse else {
      throw .Other(
        message: "Expected an HTTP response from \(request.url), got \(type(of: response))")
    }
    guard let status = UInt16(exactly: http.statusCode) else {
      throw .Other(message: "HTTP status \(http.statusCode) from \(request.url) is out of range")
    }
    return HttpResponse(status: status, headers: Self.headers(from: http), body: data)
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
