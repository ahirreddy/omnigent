import Foundation

/// The direct API root, including any deployment mount; this is not a web UI URL.
public struct ServerEndpoint: Equatable, Hashable, Sendable {
  public let baseURL: URL
  public let isLocalSingleUser: Bool
  public let databricksOrgID: String?

  public init(baseURL: URL) throws {
    guard var url = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
      let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
      url.user == nil, url.password == nil, url.fragment == nil,
      url.port.map({ (1...65_535).contains($0) }) ?? true
    else { throw LocalServerClientError.invalidBaseURL }
    var orgID: String?
    if url.query != nil {
      guard scheme == "https", Self.isDatabricksWorkspaceHost(host),
        let items = url.queryItems, items.count == 1, items[0].name == "o",
        let value = items[0].value, !value.isEmpty,
        value.utf8.allSatisfy({ (48...57).contains($0) }),
        url.percentEncodedQuery == "o=\(value)"
      else { throw LocalServerClientError.invalidBaseURL }
      orgID = value
    }
    let local = scheme == "http" && ["127.0.0.1", "::1", "[::1]"].contains(host)
    guard scheme == "https" || local,
      !local || url.path.isEmpty || url.path == "/",
      !url.percentEncodedPath.contains("%"), !url.path.contains("\\"),
      !url.path.contains("//"),
      !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    else { throw LocalServerClientError.invalidBaseURL }
    url.scheme = scheme
    url.host = host.lowercased()
    if url.path.hasSuffix("/") { url.path.removeLast() }
    if (scheme == "https" && url.port == 443) || (scheme == "http" && url.port == 80) {
      url.port = nil
    }
    guard let canonical = url.url else { throw LocalServerClientError.invalidBaseURL }
    self.baseURL = canonical
    self.isLocalSingleUser = local
    self.databricksOrgID = orgID
  }

  private static func isDatabricksWorkspaceHost(_ host: String) -> Bool {
    let host = host.lowercased()
    guard [".databricks.com", ".azuredatabricks.net"].contains(where: { host.hasSuffix($0) })
    else { return false }
    return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
      !label.isEmpty && label.first != "-" && label.last != "-"
        && label.utf8.allSatisfy {
          (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        }
    }
  }

  func request(
    path: String, query: [URLQueryItem] = [], accept: String = "application/json",
    bearerToken: String? = nil, webSocket: Bool = false
  ) throws -> URLRequest {
    guard path.hasPrefix("/"), !path.contains("//"), !path.contains("\\"),
      !path.contains("%"), !path.contains("?"), !path.contains("#"),
      !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
      databricksOrgID == nil || !query.contains(where: { $0.name == "o" }),
      var url = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    else { throw LocalServerClientError.invalidBaseURL }
    url.path += path
    url.queryItems = query.isEmpty ? nil : query
    if webSocket { url.scheme = isLocalSingleUser ? "ws" : "wss" }
    guard let target = url.url else { throw LocalServerClientError.invalidBaseURL }
    var request = URLRequest(url: target)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue(accept, forHTTPHeaderField: "Accept")
    if let databricksOrgID {
      request.setValue(databricksOrgID, forHTTPHeaderField: "X-Databricks-Org-Id")
    }
    if let bearerToken {
      try Self.validateBearer(bearerToken)
      guard !isLocalSingleUser else { throw LocalServerClientError.unsupportedAuthentication }
      request.setValue("Bearer " + bearerToken, forHTTPHeaderField: "Authorization")
    }
    return request
  }

  static func validateBearer(_ token: String) throws {
    let allowed = CharacterSet(
      charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~+/=")
    guard !token.isEmpty, token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
      throw LocalServerClientError.unauthorized
    }
  }
}

public struct ServerIdentityScope: Codable, Equatable, Hashable, Sendable {
  public let serverURL: URL
  public let userID: String

  public init(serverURL: URL, userID: String) {
    self.serverURL = serverURL
    self.userID = userID
  }
}

func secureServerConfiguration(_ session: URLSession?) -> URLSessionConfiguration {
  let configuration = session?.configuration ?? URLSessionConfiguration.ephemeral
  configuration.httpCookieStorage = nil
  configuration.httpShouldSetCookies = false
  configuration.urlCredentialStorage = nil
  configuration.httpAdditionalHeaders = nil
  configuration.urlCache = nil
  configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
  configuration.timeoutIntervalForRequest = 15
  configuration.timeoutIntervalForResource = 30
  return configuration
}

/// Keep platform certificate/hostname validation; never use stored HTTP credentials.
func handleServerChallenge(
  _ challenge: URLAuthenticationChallenge,
  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
) {
  if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
    completionHandler(.performDefaultHandling, nil)
  } else {
    completionHandler(.cancelAuthenticationChallenge, nil)
  }
}

final class ServerTransportDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) { handleServerChallenge(challenge, completionHandler: completionHandler) }
}
