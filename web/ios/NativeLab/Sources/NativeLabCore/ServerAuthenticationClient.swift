import Foundation

public enum ServerAuthenticationMode: String, Equatable, Sendable {
  case localSingleUser, accounts, oidc, proxy
}

public struct ServerAuthenticationDiscovery: Equatable, Sendable {
  public let mode: ServerAuthenticationMode
  public let baseURL: URL
  public let needsSetup: Bool
}

/// Persist only in the platform's secure credential store; never log the token.
public struct ServerCredential: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
  public let token: String
  public let userID: String
  public let expiresAt: Date

  public init(token: String, userID: String, expiresAt: Date) {
    self.token = token
    self.userID = userID
    self.expiresAt = expiresAt
  }

  public var description: String { "ServerCredential(redacted)" }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct ServerBrowserLogin: Sendable, CustomStringConvertible, CustomReflectable {
  public let loginURL: URL
  public let expiresAt: Date
  fileprivate let ticket: String
  fileprivate let baseURL: URL

  public var description: String { "ServerBrowserLogin(redacted)" }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Implements standalone accounts and the server's OIDC CLI ticket exchange.
public actor ServerAuthenticationClient {
  public let baseURL: URL
  private let endpoint: ServerEndpoint
  private let session: URLSession

  public init(baseURL: URL, session: URLSession? = nil) throws {
    let endpoint = try ServerEndpoint(baseURL: baseURL)
    self.endpoint = endpoint
    self.baseURL = endpoint.baseURL
    self.session = URLSession(
      configuration: secureServerConfiguration(session), delegate: ServerTransportDelegate(),
      delegateQueue: nil)
  }

  deinit { session.invalidateAndCancel() }

  public func discover() async throws -> ServerAuthenticationDiscovery {
    let (data, _) = try await send(endpoint.request(path: "/v1/info"))
    let info: ServerInfoWire = try decode(data)
    let mode: ServerAuthenticationMode
    if endpoint.databricksOrgID != nil {
      mode = .proxy
    } else if info.accountsEnabled {
      mode = .accounts
    } else if info.loginURL == "/auth/login" {
      mode = .oidc
    } else if info.singleUser, endpoint.isLocalSingleUser, info.loginURL == nil {
      mode = .localSingleUser
    } else {
      mode = .proxy
    }
    return ServerAuthenticationDiscovery(
      mode: mode, baseURL: baseURL, needsSetup: info.needsSetup ?? false)
  }

  public func login(username: String, password: String) async throws -> ServerCredential {
    guard !endpoint.isLocalSingleUser, endpoint.databricksOrgID == nil,
      try await discover().mode == .accounts
    else {
      throw LocalServerClientError.unsupportedAuthentication
    }
    var request = try endpoint.request(path: "/auth/login")
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(["username": username, "password": password])
    let started = Date()
    let (data, _) = try await send(request)
    let wire: AccountLoginWire = try decode(data)
    return try credential(
      token: wire.token, userID: wire.user.id,
      expiresIn: wire.expiresIn, started: started)
  }

  public func beginBrowserLogin() async throws -> ServerBrowserLogin {
    // Standalone OIDC callbacks do not establish Databricks workspace routing.
    guard !endpoint.isLocalSingleUser, endpoint.databricksOrgID == nil,
      try await discover().mode == .oidc
    else {
      throw LocalServerClientError.unsupportedAuthentication
    }
    var request = try endpoint.request(path: "/auth/cli-login")
    request.httpMethod = "POST"
    let started = Date()
    let (data, _) = try await send(request)
    let wire: BrowserLoginWire = try decode(data)
    let allowed = CharacterSet(
      charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    guard !wire.ticket.isEmpty, wire.ticket.utf8.count <= 512,
      wire.ticket.unicodeScalars.allSatisfy({ allowed.contains($0) }),
      wire.loginURL == "/auth/login?ticket=\(wire.ticket)"
    else { throw LocalServerClientError.redirectNotAllowed }
    // The server returns a logical root-relative path; map it through the API mount.
    let login = try endpoint.request(
      path: "/auth/login", query: [URLQueryItem(name: "ticket", value: wire.ticket)])
    return ServerBrowserLogin(
      loginURL: login.url!, expiresAt: started.addingTimeInterval(300),
      ticket: wire.ticket, baseURL: baseURL)
  }

  /// Poll at a modest interval while the browser is open; cancellation is caller-owned.
  public func pollBrowserLogin(_ login: ServerBrowserLogin) async throws -> ServerCredential? {
    guard login.baseURL == baseURL else { throw LocalServerClientError.redirectNotAllowed }
    guard login.expiresAt > Date() else { throw LocalServerClientError.browserLoginExpired }
    let request = try endpoint.request(
      path: "/auth/cli-poll", query: [URLQueryItem(name: "ticket", value: login.ticket)])
    let started = login.expiresAt.addingTimeInterval(-300)
    let (data, status) = try await send(request, allowPending: true)
    if status == 202 { return nil }
    let wire: BrowserPollWire = try decode(data)
    return try credential(
      token: wire.token, userID: wire.userID,
      expiresIn: wire.expiresIn, started: started)
  }

  private func credential(token: String, userID: String, expiresIn: TimeInterval, started: Date)
    throws -> ServerCredential
  {
    try ServerEndpoint.validateBearer(token)
    guard !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      expiresIn.isFinite, expiresIn > 0
    else { throw LocalServerClientError.malformedResponse }
    return ServerCredential(
      token: token, userID: userID,
      expiresAt: started.addingTimeInterval(expiresIn))
  }

  private func decode<T: Decodable>(_ data: Data) throws -> T {
    guard let value = try? JSONDecoder().decode(T.self, from: data) else {
      throw LocalServerClientError.malformedResponse
    }
    return value
  }

  private func send(_ request: URLRequest, allowPending: Bool = false) async throws -> (Data, Int) {
    let data: Data
    let response: URLResponse
    do { (data, response) = try await session.data(for: request) } catch let error as URLError {
      if error.code == .cancelled { throw CancellationError() }
      if [.userAuthenticationRequired, .userCancelledAuthentication].contains(error.code) {
        throw LocalServerClientError.unauthorized
      }
      throw LocalServerClientError.transport(error.code.rawValue)
    }
    guard let http = response as? HTTPURLResponse else {
      throw LocalServerClientError.malformedResponse
    }
    guard http.url == request.url else { throw LocalServerClientError.redirectNotAllowed }
    switch http.statusCode {
    case 200: break
    case 202 where allowPending: break
    case 300...399: throw LocalServerClientError.redirectNotAllowed
    case 401: throw LocalServerClientError.unauthorized
    case 403: throw LocalServerClientError.forbidden
    case 410 where allowPending: throw LocalServerClientError.browserLoginExpired
    default: throw LocalServerClientError.httpStatus(http.statusCode)
    }
    guard http.mimeType == "application/json" else {
      throw LocalServerClientError.malformedResponse
    }
    return (data, http.statusCode)
  }
}

struct ServerInfoWire: Decodable {
  let singleUser: Bool
  let accountsEnabled: Bool
  let loginURL: String?
  let needsSetup: Bool?
  enum CodingKeys: String, CodingKey {
    case singleUser = "single_user"
    case accountsEnabled = "accounts_enabled"
    case loginURL = "login_url"
    case needsSetup = "needs_setup"
  }
}

private struct AccountLoginWire: Decodable {
  let token: String
  let expiresIn: TimeInterval
  let user: User
  struct User: Decodable { let id: String }
  enum CodingKeys: String, CodingKey {
    case token, user
    case expiresIn = "expires_in"
  }
}

private struct BrowserLoginWire: Decodable {
  let ticket: String
  let loginURL: String
  enum CodingKeys: String, CodingKey {
    case ticket
    case loginURL = "login_url"
  }
}

private struct BrowserPollWire: Decodable {
  let token: String
  let userID: String
  let expiresIn: TimeInterval
  enum CodingKeys: String, CodingKey {
    case token
    case userID = "user_id"
    case expiresIn = "expires_in"
  }
}
