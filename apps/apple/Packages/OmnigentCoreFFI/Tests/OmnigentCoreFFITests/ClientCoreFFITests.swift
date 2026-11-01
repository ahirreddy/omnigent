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

/// Host traits the discovery tests never reach. The protocol requirements are async, so the
/// trivial witnesses are too.
final class UnusedHost: EventStreamTransport, WebSocketTransport, Clock, Scheduler, SecureStore,
  EntropySource
{
  func openStream(request: HttpRequest, sink: ByteSink) throws -> any StreamHandle {
    throw TransportError.Other(message: "streams are not used here")
  }

  func openSocket(request: HttpRequest, sink: MessageSink) throws -> any WebSocketHandle {
    throw TransportError.Other(message: "sockets are not used here")
  }

  func monotonicMs() -> UInt64 { 0 }

  func unixTimeMs() -> UInt64 { 0 }

  // swiftlint:disable:next async_without_await
  func sleep(delayMs: UInt64) async {}

  func spawn(task: CoreTask) {
    Task { await task.run() }
  }

  // swiftlint:disable:next async_without_await
  func get(key: SecureStoreKey) async throws -> Data? { nil }

  // swiftlint:disable:next async_without_await
  func set(key: SecureStoreKey, value: Data) async throws {}

  // swiftlint:disable:next async_without_await
  func delete(key: SecureStoreKey) async throws {}

  func randomBytes(len: UInt32) throws -> Data { Data(repeating: 7, count: Int(len)) }
}

private func makeCore(_ transport: CannedTransport) throws -> ClientCore {
  let host = UnusedHost()
  return try ClientCore(
    http: transport, streams: host, sockets: host, clock: host, scheduler: host,
    secureStore: host, entropy: host,
    config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
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
    let core = try makeCore(transport)

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
    let discovery = try await makeCore(transport)
      .discoverServer(serverUrl: "https://omnigent.example.com")
    #expect(discovery.authMode == .unknown(value: "saml"))
  }

  @Test func notFoundIsBaselineWithoutAuthMode() async throws {
    let transport = CannedTransport(.success(jsonResponse(Data("{}".utf8), status: 404)))
    let discovery = try await makeCore(transport)
      .discoverServer(serverUrl: "https://omnigent.example.com/")
    #expect(discovery.baseUrl == "https://omnigent.example.com")
    #expect(discovery.authMode == nil)
  }

  @Test func thrownTransportErrorKeepsItsDetail() async throws {
    let transport = CannedTransport(
      .failure(.Offline(message: "The Internet connection appears to be offline.")))
    let core = try makeCore(transport)
    await #expect(
      throws: CoreError.Transport(
        kind: .offline, message: "offline: The Internet connection appears to be offline.")
    ) {
      try await core.discoverServer(serverUrl: "https://omnigent.example.com")
    }
  }

  @Test func serverErrorStatusIsThrown() async throws {
    let transport = CannedTransport(.success(jsonResponse(Data("boom".utf8), status: 503)))
    await #expect(throws: CoreError.HttpStatus(status: 503, body: "boom")) {
      try await makeCore(transport)
        .discoverServer(serverUrl: "https://omnigent.example.com")
    }
  }

  @Test func invalidURLNeverReachesTheTransport() async throws {
    let transport = CannedTransport(.success(jsonResponse(Data())))
    await #expect(throws: CoreError.InvalidUrl(message: "Server URL is empty.")) {
      try await makeCore(transport).discoverServer(serverUrl: "  ")
    }
    #expect(transport.requests.isEmpty)
  }

  @Test func coreVersionIsReported() {
    #expect(!coreVersion().isEmpty)
  }
}
