public import Foundation

/// Why the CLI handshake could not be completed.
nonisolated public enum DeepLinkAcknowledgmentError: Error, Sendable {
  /// The request failed before a response, for example because the CLI listener had closed.
  case transport(any Error)
  /// The response was not HTTP.
  case nonHTTPResponse
}

/// Claims a CLI navigation so `omnigent start --open-in-desktop` does not also open a browser.
public protocol DeepLinkAcknowledging: Sendable {
  /// Posts the acknowledgment.
  /// - Parameter acknowledgment: The handshake from the link.
  /// - Returns: `true` only for HTTP 204, meaning the CLI handed the navigation to the desktop.
  /// - Throws: `DeepLinkAcknowledgmentError` when no response arrived.
  func acknowledge(_ acknowledgment: DeepLinkAcknowledgment)
    async throws(DeepLinkAcknowledgmentError) -> Bool
}

/// URLSession implementation: `POST http://127.0.0.1:<port>/desktop-open/<nonce>`, two-second
/// timeout, redirects refused.
nonisolated public struct LoopbackDeepLinkAcknowledger: DeepLinkAcknowledging {
  private let timeout: TimeInterval

  /// Creates an acknowledger.
  /// - Parameter timeout: Request timeout; the CLI waits five seconds in total.
  public init(timeout: TimeInterval = 2) {
    self.timeout = timeout
  }

  /// Posts the acknowledgment to the CLI's loopback listener.
  /// - Parameter acknowledgment: The handshake from the link.
  /// - Returns: `true` only for HTTP 204.
  /// - Throws: `DeepLinkAcknowledgmentError` when no HTTP response arrived.
  public func acknowledge(_ acknowledgment: DeepLinkAcknowledgment)
    async throws(DeepLinkAcknowledgmentError) -> Bool
  {
    var components = URLComponents()
    components.scheme = "http"
    components.host = "127.0.0.1"
    components.port = acknowledgment.port
    components.path = acknowledgment.callbackPath
    guard let url = components.url else {
      throw .transport(URLError(.badURL))
    }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    let response: URLResponse
    do {
      (_, response) = try await session.data(for: request, delegate: RefuseRedirects())
    } catch {
      throw .transport(error)
    }
    guard let http = response as? HTTPURLResponse else { throw .nonHTTPResponse }
    return http.statusCode == 204
  }
}

nonisolated private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  // The completion-handler form: the async form crashes SILGen in Swift 6.4.2 under
  // NonisolatedNonsendingByDefault.
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
