import Foundation

public struct NotificationScope: Codable, Equatable, Hashable, Sendable {
  public let serverURL: String
  public let userID: String
  public let workspaceID: String

  public var isLoopbackDevelopment: Bool {
    guard let url = URLComponents(string: serverURL) else { return false }
    return userID == "local" && workspaceID == "0" && url.scheme == "http"
      && ["127.0.0.1", "::1", "[::1]"].contains(url.host ?? "")
  }

  public init?(serverURL: String, userID: String, workspaceID: String = "0") {
    guard let url = URL(string: serverURL),
      let endpoint = try? ServerEndpoint(baseURL: url), !userID.isEmpty, !workspaceID.isEmpty
    else { return nil }
    self.serverURL = endpoint.baseURL.absoluteString
    self.userID = userID
    self.workspaceID = workspaceID
  }
}

public enum NativeNotificationKind: String, Codable, Sendable {
  case approval
  case completed
  case failed
}

public struct NotificationRoute: Equatable, Sendable {
  public let scope: NotificationScope
  public let sessionID: String
  public let eventID: String
  public let kind: NativeNotificationKind

  /// Accept only the versioned, scoped native payload; never navigate an arbitrary URL.
  public init?(userInfo: [AnyHashable: Any]) {
    guard let value = userInfo["omnigent"] as? [String: Any],
      value["version"] as? Int == 1,
      let server = value["server_url"] as? String,
      let user = value["user_id"] as? String,
      let workspace = value["workspace_id"] as? String,
      let scope = NotificationScope(serverURL: server, userID: user, workspaceID: workspace),
      let session = value["session_id"] as? String, Self.validIdentifier(session),
      let event = value["event_id"] as? String, Self.validIdentifier(event),
      let rawKind = value["kind"] as? String,
      let kind = NativeNotificationKind(rawValue: rawKind)
    else { return nil }
    self.scope = scope
    sessionID = session
    eventID = event
    self.kind = kind
  }

  public static func validIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || $0 == 45 || $0 == 95
      }
  }

  public var deduplicationKey: String {
    // JSON encoding avoids ambiguous delimiters in server/account identifiers.
    let fields = [scope.serverURL, scope.userID, scope.workspaceID, sessionID, eventID]
    return String(data: try! JSONEncoder().encode(fields), encoding: .utf8)!
  }
}

/// Separate presentation and activation ledgers: showing a banner must not consume its tap.
public struct NotificationLedger: Codable, Sendable {
  private var keys: [String] = []
  public init() {}

  public mutating func insert(_ route: NotificationRoute) -> Bool {
    let key = route.deduplicationKey
    guard !keys.contains(key) else { return false }
    keys.append(key)
    if keys.count > 512 { keys.removeFirst(keys.count - 512) }
    return true
  }
}

public enum NativeNotificationPermission: String, Sendable {
  case unknown, notDetermined, denied, authorized, provisional
}

public struct NativePushCapabilities: Decodable, Equatable, Sendable {
  public let available: Bool
  public let missingConfiguration: [String]
  public let serverURL: String?
  public let environment: String?
  public let topic: String?
  public let workspaceID: String
  public let localDevelopment: Bool?

  enum CodingKeys: String, CodingKey {
    case available, environment, topic
    case missingConfiguration = "missing_configuration"
    case serverURL = "server_url"
    case workspaceID = "workspace_id"
    case localDevelopment = "local_development"
  }
}

public struct NativePushRegistration: Encodable, Equatable, Sendable {
  public let installationID: String
  public let deviceToken: String
  public let environment: String
  public let topic: String
  public let sessionIDs: [String]

  public init(
    installationID: String, deviceToken: String, environment: String, topic: String,
    sessionIDs: [String]
  ) {
    self.installationID = installationID
    self.deviceToken = deviceToken
    self.environment = environment
    self.topic = topic
    self.sessionIDs = Array(Set(sessionIDs)).sorted()
  }

  enum CodingKeys: String, CodingKey {
    case environment, topic
    case installationID = "installation_id"
    case deviceToken = "device_token"
    case sessionIDs = "session_ids"
  }
}

/// The host supplies authenticated transport or an explicitly enabled single-user loopback client.
public protocol NativePushRegistrationClient: Sendable {
  func capabilities() async throws -> NativePushCapabilities
  func register(_ registration: NativePushRegistration) async throws
  func unregister(installationID: String) async throws
}

public struct HTTPNativePushRegistrationClient: NativePushRegistrationClient {
  public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
  private let endpoint: ServerEndpoint
  private let transport: Transport

  /// Transport must preserve account auth and refuse redirects (including same-origin redirects).
  public init(baseURL: URL, transport: @escaping Transport) throws {
    let endpoint = try ServerEndpoint(baseURL: baseURL)
    guard !endpoint.isLocalSingleUser else { throw LocalServerClientError.invalidBaseURL }
    self.endpoint = endpoint
    self.transport = transport
  }

  public func capabilities() async throws -> NativePushCapabilities {
    try JSONDecoder().decode(
      NativePushCapabilities.self,
      from: await request(path: "capabilities", method: "GET"))
  }

  public func register(_ registration: NativePushRegistration) async throws {
    _ = try await request(
      path: "devices", method: "PUT",
      body: JSONEncoder().encode(registration))
  }

  public func unregister(installationID: String) async throws {
    guard NotificationRoute.validIdentifier(installationID) else {
      throw LocalServerClientError.invalidIdentifier
    }
    _ = try await request(path: "devices/\(installationID)", method: "DELETE")
  }

  private func request(path: String, method: String, body: Data? = nil) async throws -> Data {
    var request = try endpoint.request(path: "/v1/notifications/\(path)")
    request.httpMethod = method
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (data, response) = try await transport(request)
    guard response.url == request.url else { throw LocalServerClientError.redirectNotAllowed }
    guard (200...299).contains(response.statusCode) else {
      throw LocalServerClientError.httpStatus(response.statusCode)
    }
    return data
  }
}
