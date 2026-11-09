import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentServices

/// The HTTP contract's edges: no redirects followed, no stored state, odd responses refused.
@Suite("HTTP transport edges") struct HttpTransportEdgeTests {
  private func request(_ url: String) -> HttpRequest {
    HttpRequest(method: "GET", url: url, headers: [], body: nil)
  }

  @Test("A redirect comes back as the response; the core decides whether to follow it")
  func redirectIsNotFollowed() async throws {
    let server = try await MockHTTPServer.start { request in
      request.path == "/elsewhere"
        ? .complete(status: 200, headers: [:], body: Data())
        : .complete(status: 302, headers: ["Location": "/elsewhere"], body: Data())
    }
    defer { server.stop() }
    let response = try await URLSessionHttpTransport().send(
      request: request(server.url(for: "/start")))
    #expect(response.status == 302)
    #expect(response.headers.contains { $0.name == "Location" && $0.value == "/elsewhere" })
    #expect(!server.requests.contains { $0.path == "/elsewhere" })
  }

  @Test("The default session keeps no cookies or cache and fails fast when offline")
  func defaultSession() throws {
    let configuration = URLSessionHttpTransport.makeDefaultSession().configuration
    #expect(configuration.httpCookieStorage == nil)
    #expect(!configuration.httpShouldSetCookies)
    #expect(configuration.httpCookieAcceptPolicy == .never)
    #expect(configuration.urlCache == nil)
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(!configuration.waitsForConnectivity)
    #expect(configuration.timeoutIntervalForRequest == 30)
  }

  @Test("A transport error passes through the mapping unchanged")
  func mappingPassThrough() {
    guard case .Cancelled = TransportErrorMapping.map(TransportError.Cancelled) else {
      Issue.record("expected the error back")
      return
    }
  }
}

/// WebSocket edges the core can hit while closing or after the link ended.
@Suite("WebSocket edges") struct WebSocketEdgeTests {
  private func request(_ url: String) -> HttpRequest {
    HttpRequest(method: "GET", url: url, headers: [], body: nil)
  }

  private func hasEnded(_ sink: RecordingMessageSink) -> Bool {
    sink.snapshot.contains { if case .ended = $0 { true } else { false } }
  }

  @Test("A close code outside the standard ones still ends the socket")
  func unsupportedCloseCode() async throws {
    let server = try await MockWebSocketServer.start()
    defer { server.stop() }
    let sink = RecordingMessageSink()
    let handle = try URLSessionWebSocketTransport().startSocket(
      request: request(server.url), sink: sink)
    #expect(await eventually { sink.snapshot.contains(.opened) })

    handle.close(code: 4_999, reason: "custom")
    #expect(await eventually { hasEnded(sink) })
  }

  @Test("Binary input sent after the link ended throws instead of vanishing")
  func binaryAfterEnd() async throws {
    let server = try await MockWebSocketServer.start()
    defer { server.stop() }
    let sink = RecordingMessageSink()
    let handle = try URLSessionWebSocketTransport().startSocket(
      request: request(server.url), sink: sink)
    #expect(await eventually { sink.snapshot.contains(.opened) })
    try await server.sendClose(code: 1_000, reason: "")
    #expect(await eventually { hasEnded(sink) })

    await #expect(throws: TransportError.self) {
      try await handle.sendBinary(bytes: Data([1, 2, 3]))
    }
  }
}

/// Stored values at the edges of what the host can keep.
@Suite("Storage edges", .serialized) struct StorageEdgeTests {
  private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "storage-edges-\(UUID().uuidString)")
  }

  private let key = SecureStoreKey(namespace: "oidc", account: "https://example.com")

  @Test("A credential that can't be written says which and where")
  func credentialWriteFails() throws {
    let blocker = temporaryFolder()
    defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: blocker) } }
    try Data().write(to: blocker)
    let store = CredentialFileStore(directory: blocker)
    #expect(throws: SecureStoreError.self) {
      try store.set(key: key, value: Data("x".utf8))
    }
  }

  @Test("A credential that can't be deleted is an error, because sign-out relies on it")
  func credentialDeleteFails() throws {
    let folder = temporaryFolder()
    let store = CredentialFileStore(directory: folder)
    try store.set(key: key, value: Data("x".utf8))
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer {
      #expect(throws: Never.self) {
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try FileManager.default.removeItem(at: folder)
      }
    }
    #expect(throws: SecureStoreError.self) { try store.delete(key: key) }
    #expect(try store.get(key: key) == Data("x".utf8))
  }

  @Test("A locked Keychain is retryable; any other failure isn't")
  func keychainFailureKinds() {
    guard
      case .Unavailable = KeychainSecureStore.failure(
        errSecInteractionNotAllowed, operation: "read")
    else {
      Issue.record("a locked Keychain should read as unavailable")
      return
    }
    guard case .Other(let message) = KeychainSecureStore.failure(errSecParam, operation: "read")
    else {
      Issue.record("a bad parameter should not be retryable")
      return
    }
    #expect(message.contains("could not read"))
  }

  @Test("Managed dictionaries convert all the way down")
  func nestedManagedValues() throws {
    let text = try ManagedPreferencesSource.jsonText(
      for: ["flag": true, "list": [1, "two"], "inner": ["ok": false]] as [String: Any])
    let decoded = try #require(
      try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(decoded["flag"] as? Bool == true)
    #expect((decoded["list"] as? [Any])?.count == 2)
    #expect((decoded["inner"] as? [String: Any])?["ok"] as? Bool == false)
    #expect(throws: ManagedPreferenceError.self) {
      try ManagedPreferencesSource.jsonText(for: ["bad": Double.infinity] as [String: Any])
    }
  }
}
