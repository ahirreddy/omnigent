import Foundation
import XCTest

@testable import NativeLabCore

final class LocalAttachmentTests: XCTestCase {
  func testReferenceResolutionAcceptsOnlyExactSessionResources() throws {
    let client = try LocalServerSessionClient(baseURL: URL(string: "http://127.0.0.1:6767")!)
    for reference in [
      "file_123-abc", "/v1/sessions/fixture/resources/files/file_123-abc/content",
      "http://127.0.0.1:6767/v1/sessions/fixture/resources/files/file_123-abc/content",
    ] {
      XCTAssertEqual(
        client.attachmentFileID(reference: reference, sessionID: "fixture"), "file_123-abc",
        reference)
    }
    for reference in [
      "", "file/name", "../file", "file name", "data:image/png;base64,AAAA",
      "file:///private/tmp/fixture.png", "https://example.invalid/fixture.png",
      "http://127.0.0.1:6768/v1/sessions/fixture/resources/files/file/content",
      "http://localhost:6767/v1/sessions/fixture/resources/files/file/content",
      "https://127.0.0.1:6767/v1/sessions/fixture/resources/files/file/content",
      "http://127.0.0.1:6767/v1/sessions/other/resources/files/file/content",
      "http://user:password@127.0.0.1:6767/v1/sessions/fixture/resources/files/file/content",
      "/v1/sessions/fixture/resources/files/file/content?download=1",
      "/v1/sessions/fixture/resources/files/file/content#fragment",
      "/v1/sessions/fixture/resources/files/%2Fetc%2Fpasswd/content",
      "/v1/sessions/fixture/resources/files/file/content/extra",
    ] {
      XCTAssertNil(client.attachmentFileID(reference: reference, sessionID: "fixture"), reference)
    }
    XCTAssertNil(client.attachmentFileID(reference: nil, sessionID: "fixture"))
    XCTAssertNil(client.attachmentFileID(reference: "file", sessionID: "../other"))
  }

  func testExplicitFetchUsesSessionResourceGETAndPreservesBytesWithoutCredentials() async throws {
    let harness = AttachmentHarness()
    let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a])
    harness.set(.init(data: bytes, mime: "image/png"))
    let client = try harness.client()
    _ = try await client.connect()
    let content = try await client.attachmentContent(sessionID: "fixture", fileID: "file_1")
    XCTAssertEqual(content.data, bytes)
    XCTAssertEqual(content.fileExtension, "png")
    let request = try XCTUnwrap(harness.requests.last)
    XCTAssertEqual(request.url?.path, "/v1/sessions/fixture/resources/files/file_1/content")
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertNil(request.httpBody)
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertEqual(harness.requests.count, 3)
  }

  func testDisconnectedAndMalformedIdentifiersMakeNoAttachmentRequests() async throws {
    let harness = AttachmentHarness()
    let client = try harness.client()
    do {
      _ = try await client.attachmentContent(sessionID: "fixture", fileID: "file")
      XCTFail("Connection is required")
    } catch {
      XCTAssertEqual(error as? LocalServerClientError, .notConnected)
    }
    XCTAssertTrue(harness.requests.isEmpty)
    _ = try await client.connect()
    for (session, file) in [("../other", "file"), ("fixture", "../file"), ("fixture", "")] {
      do {
        _ = try await client.attachmentContent(sessionID: session, fileID: file)
        XCTFail("Invalid identifiers must be rejected")
      } catch {
        XCTAssertEqual(error as? LocalServerClientError, .invalidIdentifier)
      }
    }
    XCTAssertEqual(harness.requests.count, 2)
  }

  func testSupportedMIMETypesHaveFixedSafeExtensions() async throws {
    let harness = AttachmentHarness()
    let client = try harness.client()
    _ = try await client.connect()
    let types = [
      "application/pdf": "pdf", "text/plain; charset=utf-8": "txt", "application/json": "json",
      "text/markdown": "txt", "text/csv": "csv", "image/png": "png", "image/jpeg": "jpg",
      "image/gif": "gif", "image/webp": "webp", "image/heic": "heic", "image/tiff": "tiff",
      "audio/mpeg": "mp3", "audio/wav": "wav", "audio/x-wav": "wav", "audio/mp4": "m4a",
      "video/mp4": "mp4", "video/quicktime": "mov",
    ]
    for (mime, ext) in types {
      harness.set(.init(data: Data("fixture".utf8), mime: mime))
      let content = try await client.attachmentContent(sessionID: "fixture", fileID: "file")
      XCTAssertEqual(content.fileExtension, ext, mime)
      XCTAssertEqual(content.data, Data("fixture".utf8), mime)
    }
  }

  func testUnsupportedActiveOrUnknownMIMEIsRejected() async throws {
    let harness = AttachmentHarness()
    let client = try harness.client()
    _ = try await client.connect()
    for mime in [
      "text/html", "image/svg+xml", "application/javascript", "application/octet-stream", "",
    ] {
      harness.set(.init(data: Data("not a preview".utf8), mime: mime))
      do {
        _ = try await client.attachmentContent(sessionID: "fixture", fileID: "file")
        XCTFail("Unexpected preview for \(mime)")
      } catch {
        XCTAssertEqual(error as? AttachmentPreviewError, .unsupportedMedia, mime)
      }
    }
  }

  func testAdvertisedContentLengthOverLimitIsRejected() async throws {
    let harness = AttachmentHarness()
    harness.set(.init(data: Data(), mime: "text/plain", contentLength: 10 * 1_024 * 1_024 + 1))
    let client = try harness.client()
    _ = try await client.connect()
    do {
      _ = try await client.attachmentContent(sessionID: "fixture", fileID: "file")
      XCTFail("Advertised oversized files must not be read")
    } catch {
      XCTAssertEqual(error as? AttachmentPreviewError, .tooLarge)
    }
  }

  func testStreamingLengthLimitDoesNotTrustMissingContentLength() async throws {
    let harness = AttachmentHarness()
    harness.set(.init(data: Data(repeating: 65, count: 10 * 1_024 * 1_024 + 1), mime: "text/plain"))
    let client = try harness.client()
    _ = try await client.connect()
    do {
      _ = try await client.attachmentContent(sessionID: "fixture", fileID: "file")
      XCTFail("The streamed body must have its own size limit")
    } catch {
      XCTAssertEqual(error as? AttachmentPreviewError, .tooLarge)
    }
  }

  func testRedirectsDifferentResponseOriginsAndHTTPFailuresAreExplicit() async throws {
    let harness = AttachmentHarness()
    let client = try harness.client()
    _ = try await client.connect()
    for (status, expected) in [
      (302, LocalServerClientError.redirectNotAllowed), (401, .unauthorized), (403, .forbidden),
      (404, .httpStatus(404)), (500, .httpStatus(500)),
    ] {
      harness.set(.init(data: Data(), mime: "text/plain", status: status))
      do {
        _ = try await client.attachmentContent(sessionID: "fixture", fileID: "file")
        XCTFail("Expected failure for HTTP \(status)")
      } catch {
        XCTAssertEqual(error as? LocalServerClientError, expected)
      }
      if status == 401 {
        let connected = await client.connected
        XCTAssertFalse(connected)
        let before = harness.requests.count
        do {
          _ = try await client.attachmentContent(sessionID: "fixture", fileID: "file")
          XCTFail("Authentication loss must revoke subsequent reads")
        } catch {
          XCTAssertEqual(error as? LocalServerClientError, .notConnected)
        }
        XCTAssertEqual(harness.requests.count, before)
        _ = try await client.connect()
      }
    }
    harness.set(
      .init(
        data: Data(), mime: "text/plain", responseURL: URL(string: "https://example.invalid/file")))
    do {
      _ = try await client.attachmentContent(sessionID: "fixture", fileID: "file")
      XCTFail("Cross-origin response must be rejected")
    } catch {
      XCTAssertEqual(error as? LocalServerClientError, .redirectNotAllowed)
    }
    XCTAssertEqual(harness.requests.count, 10)
  }
}

private final class AttachmentHarness: @unchecked Sendable {
  struct Stub {
    var data: Data
    var mime: String
    var status = 200
    var contentLength: Int?
    var responseURL: URL?
  }

  let port: Int
  private let lock = NSLock()
  private var recorded: [URLRequest] = []
  private var stub = Stub(data: Data(), mime: "text/plain")

  init() {
    port = AttachmentProtocol.register()
    AttachmentProtocol.attach(self, port: port)
  }

  deinit { AttachmentProtocol.remove(port: port) }

  var requests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func client() throws -> LocalServerSessionClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AttachmentProtocol.self]
    config.httpAdditionalHeaders = [
      "Authorization": "fixture-must-not-send", "Cookie": "fixture-must-not-send",
    ]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    return try LocalServerSessionClient(
      baseURL: URL(string: "http://127.0.0.1:\(port)")!, session: session)
  }

  func set(_ value: Stub) {
    lock.lock()
    defer { lock.unlock() }
    stub = value
  }

  func response(for request: URLRequest) -> Stub {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(request)
    switch request.url?.path {
    case "/v1/info":
      return Stub(
        data: Data(#"{"single_user":true,"accounts_enabled":false}"#.utf8), mime: "application/json"
      )
    case "/v1/me":
      return Stub(
        data: Data(#"{"user_id":"local","is_admin":true}"#.utf8), mime: "application/json")
    default: return stub
    }
  }
}

private final class WeakAttachmentHarness {
  weak var value: AttachmentHarness?
  init(_ value: AttachmentHarness) { self.value = value }
}

private final class AttachmentProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  private static var nextPort = 42_000
  private static var registry: [Int: WeakAttachmentHarness] = [:]

  static func register() -> Int {
    lock.lock()
    defer { lock.unlock() }
    nextPort += 1
    return nextPort
  }

  static func attach(_ value: AttachmentHarness, port: Int) {
    lock.lock()
    defer { lock.unlock() }
    registry[port] = WeakAttachmentHarness(value)
  }

  static func remove(port: Int) {
    lock.lock()
    defer { lock.unlock() }
    registry.removeValue(forKey: port)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    let harness = Self.registry[request.url?.port ?? 0]?.value
    Self.lock.unlock()
    guard let harness else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    let stub = harness.response(for: request)
    var headers = stub.mime.isEmpty ? [:] : ["Content-Type": stub.mime]
    if let length = stub.contentLength { headers["Content-Length"] = String(length) }
    let response = HTTPURLResponse(
      url: stub.responseURL ?? request.url!, statusCode: stub.status,
      httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !stub.data.isEmpty { client?.urlProtocol(self, didLoad: stub.data) }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
