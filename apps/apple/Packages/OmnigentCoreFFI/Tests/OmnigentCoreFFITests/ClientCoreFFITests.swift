import Foundation
import OmnigentCoreFFI
import Synchronization
import Testing

/// Answers every request with one canned result and records what it was asked to send.
final class CannedTransport: HttpTransport {
  private let result: Result<HttpResponse, TransportError>
  private let sent = Mutex<[HttpRequest]>([])

  init(_ result: Result<HttpResponse, TransportError>) {
    self.result = result
  }

  var requests: [HttpRequest] { sent.withLock { $0 } }

  func send(request: HttpRequest) async throws -> HttpResponse {
    sent.withLock { $0.append(request) }
    await Task.yield()
    return try result.get()
  }
}

private func jsonResponse(_ body: Data, status: UInt16 = 200) -> HttpResponse {
  HttpResponse(
    status: status,
    headers: [HttpHeader(name: "Content-Type", value: "application/json; charset=utf-8")],
    body: body)
}

private func fixture(_ name: String) throws -> Data {
  // <repo>/apps/apple/Packages/OmnigentCoreFFI/Tests/OmnigentCoreFFITests/<this file>
  var repoRoot = URL(filePath: #filePath)
  for _ in 0..<7 { repoRoot.deleteLastPathComponent() }
  return try Data(contentsOf: repoRoot.appending(path: "client-core/fixtures/manifest/\(name)"))
}

@Suite struct ClientCoreFFITests {
  @Test func discoversServerThroughSwiftTransport() async throws {
    let transport = CannedTransport(.success(jsonResponse(try fixture("oidc.json"))))
    let core = ClientCore(transport: transport)

    let discovery = try await core.discoverServer(serverUrl: "localhost:6767/omnigent")

    #expect(
      discovery
        == ServerDiscovery(
          baseUrl: "http://localhost:6767/omnigent",
          serverName: "Omnigent Dev",
          serverVersion: "0.18.0",
          minClientVersion: nil,
          authMode: .oidc,
          nativeRedirectUris: [
            "ai.omnigent.android:/oauth/callback", "ai.omnigent.ios:/oauth/callback",
          ]))
    let requests = transport.requests
    #expect(requests.count == 1)
    #expect(requests.first?.method == "GET")
    #expect(requests.first?.url == "http://localhost:6767/.well-known/omnigent.json")
    #expect(requests.first?.headers == [HttpHeader(name: "Accept", value: "application/json")])
    #expect(requests.first?.body == nil)
  }

  @Test func unknownAuthModeIsSurfaced() async throws {
    let transport = CannedTransport(.success(jsonResponse(try fixture("unknown-mode.json"))))
    let discovery = try await ClientCore(transport: transport)
      .discoverServer(serverUrl: "https://omnigent.example.com")
    #expect(discovery.authMode == .unknown(value: "saml"))
  }

  @Test func notFoundIsBaselineWithoutAuthMode() async throws {
    let transport = CannedTransport(.success(jsonResponse(Data("{}".utf8), status: 404)))
    let discovery = try await ClientCore(transport: transport)
      .discoverServer(serverUrl: "https://omnigent.example.com/")
    #expect(discovery.baseUrl == "https://omnigent.example.com")
    #expect(discovery.authMode == nil)
  }

  @Test func thrownTransportErrorKeepsItsDetail() async throws {
    let transport = CannedTransport(
      .failure(.Offline(message: "The Internet connection appears to be offline.")))
    let core = ClientCore(transport: transport)
    await #expect(
      throws: CoreError.Transport(message: "offline: The Internet connection appears to be offline.")
    ) {
      try await core.discoverServer(serverUrl: "https://omnigent.example.com")
    }
  }

  @Test func serverErrorStatusIsThrown() async throws {
    let transport = CannedTransport(.success(jsonResponse(Data("boom".utf8), status: 503)))
    await #expect(throws: CoreError.HttpStatus(status: 503, body: "boom")) {
      try await ClientCore(transport: transport)
        .discoverServer(serverUrl: "https://omnigent.example.com")
    }
  }

  @Test func invalidURLNeverReachesTheTransport() async throws {
    let transport = CannedTransport(.success(jsonResponse(Data())))
    await #expect(throws: CoreError.InvalidUrl(message: "Server URL is empty.")) {
      try await ClientCore(transport: transport).discoverServer(serverUrl: "  ")
    }
    #expect(transport.requests.isEmpty)
  }

  @Test func coreVersionIsReported() {
    #expect(!coreVersion().isEmpty)
  }
}
