import Foundation

extension LocalServerSessionClient: NativePushRegistrationClient {
  public func capabilities() async throws -> NativePushCapabilities {
    try requireConnection()
    return try await get(path: "/v1/notifications/capabilities")
  }

  public func register(_ registration: NativePushRegistration) async throws {
    try requireConnection()
    var outgoing = try request(path: "/v1/notifications/devices")
    outgoing.httpMethod = "PUT"
    outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
    outgoing.httpBody = try JSONEncoder().encode(registration)
    try await notificationMutation(outgoing)
  }

  public func unregister(installationID: String) async throws {
    try requireConnection()
    try validateIdentifier(installationID)
    var outgoing = try request(path: "/v1/notifications/devices/\(installationID)")
    outgoing.httpMethod = "DELETE"
    try await notificationMutation(outgoing)
  }

  private func notificationMutation(_ request: URLRequest) async throws {
    let generation = connectionGeneration
    let response: URLResponse
    do { (_, response) = try await session.data(for: request) } catch {
      throw LocalServerClientError.deliveryUncertain
    }
    guard generation == connectionGeneration else { throw LocalServerClientError.deliveryUncertain }
    guard let http = response as? HTTPURLResponse else {
      throw LocalServerClientError.malformedResponse
    }
    guard http.url == request.url else { throw LocalServerClientError.redirectNotAllowed }
    switch http.statusCode {
    case 204: return
    case 300...399: throw LocalServerClientError.redirectNotAllowed
    case 401:
      authenticationFailed()
      throw LocalServerClientError.unauthorized
    case 403: throw LocalServerClientError.forbidden
    default: throw LocalServerClientError.httpStatus(http.statusCode)
    }
  }
}
