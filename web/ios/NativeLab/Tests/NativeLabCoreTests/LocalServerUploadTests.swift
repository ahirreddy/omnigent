import Foundation
import XCTest

@testable import NativeLabCore

final class LocalServerUploadTests: XCTestCase {
  func testUpload201UsesExactMultipartFieldBytesAndSafeSessionTransport() async throws {
    let harness = UploadFixtureHarness()
    let client = try harness.client()
    _ = try await client.connect()
    let file = try AttachmentUploadFile(filename: "screen\"shot.png", data: Data([0, 1, 2, 255]))
    let uploaded = try await client.uploadAttachment(file, sessionID: "session_a")
    XCTAssertEqual(uploaded.id, "file_exact")
    XCTAssertEqual(uploaded.filename, "server-name.png")
    XCTAssertTrue(uploaded.isImage)
    XCTAssertEqual(uploaded.sessionID, "session_a")
    let request = try XCTUnwrap(harness.posts.first)
    XCTAssertEqual(harness.posts.count, 1)
    XCTAssertEqual(request.url?.path, "/v1/sessions/session_a/resources/files")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
    let type = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
    XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary=NativeLab-"))
    let boundary = String(type.split(separator: "=").last!)
    var expected = Data(
      ("--\(boundary)\r\n"
        + "Content-Disposition: form-data; name=\"file\"; filename=\"screen%22shot.png\"\r\n"
        + "Content-Type: image/png\r\n\r\n").utf8)
    expected.append(file.data)
    expected.append(Data("\r\n--\(boundary)--\r\n".utf8))
    XCTAssertEqual(request.httpBody, expected)
  }

  func testMessageUsesUploadedRefsBeforeExactTextAndSupportsAttachmentsOnly() async throws {
    let harness = UploadFixtureHarness()
    let client = try harness.client()
    _ = try await client.connect()
    await client.prepareAttachmentStream()
    let image = try await client.uploadAttachment(
      AttachmentUploadFile(filename: "photo.png", data: Data([1])), sessionID: "session_a")
    harness.setUpload(body: #"{"id":"file_text","name":"notes.txt"}"#)
    let file = try await client.uploadAttachment(
      AttachmentUploadFile(filename: "notes.txt", data: Data("notes".utf8)), sessionID: "session_a")
    let text = "  explain these\nexactly  "
    let result = try await client.submitMessage(text, attachments: [image, file], to: "session_a")
    XCTAssertEqual(result.pendingID, "pending_exact")
    let body = try JSONDecoder().decode(
      JSONValue.self, from: XCTUnwrap(harness.posts.last?.httpBody))
    XCTAssertEqual(
      body,
      .object([
        "type": .string("message"),
        "data": .object([
          "role": .string("user"),
          "content": .array([
            .object([
              "type": .string("input_image"), "file_id": .string("file_exact"),
              "filename": .string("server-name.png"),
            ]),
            .object([
              "type": .string("input_file"), "file_id": .string("file_text"),
              "filename": .string("notes.txt"),
            ]),
            .object(["type": .string("input_text"), "text": .string(text)]),
          ]),
        ]),
      ]))
    _ = try await client.submitMessage(" \n", attachments: [file], to: "session_a")
    let onlyFile = try JSONDecoder().decode(
      JSONValue.self, from: XCTUnwrap(harness.posts.last?.httpBody))
    XCTAssertEqual(onlyFile.object?["data"]?.object?["content"], .array([file.contentBlock]))
    XCTAssertEqual(harness.posts.count, 4)
  }

  func testUploadFallbackFilenameMatchesWebContract() async throws {
    let harness = UploadFixtureHarness()
    let client = try harness.client()
    _ = try await client.connect()
    harness.setUpload(body: #"{"id":"file_fallback"}"#)
    let ref = try await client.uploadAttachment(
      AttachmentUploadFile(filename: "actual.swift", data: Data()), sessionID: "session_a")
    XCTAssertEqual(ref.filename, "actual.swift")
    XCTAssertFalse(ref.isImage)
  }

  func testIndeterminateUploadFailuresDoNotRetryPOST() async throws {
    let harness = UploadFixtureHarness()
    let client = try harness.client()
    _ = try await client.connect()
    let cases: [UploadFixtureHarness.Response] = [
      .init(status: 500), .init(body: "invalid", status: 201),
      .init(body: #"{"id":"../wrong"}"#, status: 201),
      .init(error: .networkConnectionLost), .init(error: .cancelled),
      .init(body: #"{"id":"file"}"#, status: 201, url: URL(string: "http://127.0.0.1:1/other")),
    ]
    for response in cases {
      harness.setUpload(response)
      let before = harness.posts.count
      do {
        _ = try await client.uploadAttachment(
          AttachmentUploadFile(filename: "notes.txt", data: Data()), sessionID: "session_a")
        XCTFail("Uncertain upload must not be treated as successful")
      } catch { XCTAssertEqual(error as? AttachmentUploadError, .uploadUncertain) }
      XCTAssertEqual(harness.posts.count, before + 1)
    }
    XCTAssertFalse(harness.posts.contains { $0.url?.path.hasSuffix("/events") == true })
  }

  func testRejectedUploadCanBeReportedWithoutSendingTranscriptMessage() async throws {
    let harness = UploadFixtureHarness()
    let client = try harness.client()
    _ = try await client.connect()
    for (status, expected) in [
      (403, LocalServerClientError.forbidden), (413, .httpStatus(413)), (415, .httpStatus(415)),
    ] {
      harness.setUpload(.init(status: status))
      do {
        _ = try await client.uploadAttachment(
          AttachmentUploadFile(filename: "notes.txt", data: Data()), sessionID: "session_a")
        XCTFail("Expected rejection")
      } catch { XCTAssertEqual(error as? LocalServerClientError, expected) }
    }
    XCTAssertEqual(harness.posts.count, 3)
    XCTAssertTrue(harness.posts.allSatisfy { $0.url?.path.hasSuffix("/resources/files") == true })
    harness.setUpload(.init(status: 401))
    do {
      _ = try await client.uploadAttachment(
        AttachmentUploadFile(filename: "notes.txt", data: Data()), sessionID: "session_a")
      XCTFail("Authentication must revoke connection")
    } catch { XCTAssertEqual(error as? LocalServerClientError, .unauthorized) }
    let connected = await client.connected
    XCTAssertFalse(connected)
  }

  func testPreflightBlocksWrongScopeReadOnlyArchiveAndUnreadyStreamWithoutPOST() async throws {
    let harness = UploadFixtureHarness()
    let client = try harness.client()
    let file = try AttachmentUploadFile(filename: "notes.txt", data: Data())
    do {
      _ = try await client.uploadAttachment(file, sessionID: "session_a")
      XCTFail("Disconnected")
    } catch { XCTAssertEqual(error as? LocalServerClientError, .notConnected) }
    XCTAssertTrue(harness.requests.isEmpty)
    _ = try await client.connect()
    do {
      _ = try await client.uploadAttachment(file, sessionID: "../wrong")
      XCTFail("Invalid identifier")
    } catch { XCTAssertEqual(error as? LocalServerClientError, .invalidIdentifier) }
    for (summary, expected) in [
      (
        #"{"id":"session_a","status":"idle","created_at":1,"permission_level":1}"#,
        SessionClientError.readOnly
      ),
      (
        #"{"id":"session_a","status":"idle","created_at":1,"permission_level":4,"archived":true}"#,
        SessionClientError.archived
      ),
    ] {
      harness.setSummary(summary)
      do {
        _ = try await client.uploadAttachment(file, sessionID: "session_a")
        XCTFail("Session cannot be edited")
      } catch { XCTAssertEqual(error as? SessionClientError, expected) }
    }
    harness.setSummary(#"{"id":"session_a","status":"idle","created_at":1,"permission_level":4}"#)
    let baseURL = await client.baseURL
    let ref = UploadedAttachment(
      serverURL: baseURL, sessionID: "session_a", id: "file_x", filename: "notes.txt",
      isImage: false)
    do {
      _ = try await client.submitMessage("text", attachments: [ref], to: "session_a")
      XCTFail("Stream must be ready")
    } catch { XCTAssertEqual(error as? LocalServerClientError, .streamNotReady) }
    for wrong in [
      UploadedAttachment(
        serverURL: baseURL, sessionID: "session_b", id: "file_x", filename: "notes.txt",
        isImage: false),
      UploadedAttachment(
        serverURL: URL(string: "http://127.0.0.1:1")!, sessionID: "session_a", id: "file_x",
        filename: "notes.txt", isImage: false),
    ] {
      do {
        _ = try await client.submitMessage("text", attachments: [wrong], to: "session_a")
        XCTFail("Foreign reference")
      } catch { XCTAssertEqual(error as? AttachmentUploadError, .wrongSession) }
    }
    XCTAssertTrue(harness.posts.isEmpty)
  }
}

extension LocalServerSessionClient {
  fileprivate func prepareAttachmentStream() {
    watchedSessionID = "session_a"
    streamReady = true
  }
}

final class UploadFixtureHarness: @unchecked Sendable {
  struct Response {
    var body = ""
    var status = 200
    var error: URLError.Code?
    var url: URL?
  }
  let port: Int
  private let lock = NSLock()
  private var recorded: [URLRequest] = []
  private var upload = Response(
    body: #"{"id":"file_exact","metadata":{"filename":"server-name.png","bytes":4}}"#, status: 201)
  private var message = Response(
    body: #"{"queued":true,"pending_id":"pending_exact"}"#, status: 202)
  private var summary = #"{"id":"session_a","status":"idle","created_at":1,"permission_level":4}"#

  init() {
    port = UploadFixtureProtocol.register()
    UploadFixtureProtocol.attach(self, port: port)
  }
  deinit { UploadFixtureProtocol.remove(port) }

  var requests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
  var posts: [URLRequest] { requests.filter { $0.httpMethod == "POST" } }

  func client() throws -> LocalServerSessionClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UploadFixtureProtocol.self]
    configuration.httpAdditionalHeaders = [
      "Authorization": "must-not-send", "Cookie": "must-not-send",
    ]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    return try LocalServerSessionClient(
      baseURL: URL(string: "http://127.0.0.1:\(port)")!, session: session)
  }
  func setUpload(body: String) { setUpload(Response(body: body, status: 201)) }
  func setUpload(_ response: Response) {
    lock.lock()
    defer { lock.unlock() }
    upload = response
  }
  func setMessage(_ response: Response) {
    lock.lock()
    defer { lock.unlock() }
    message = response
  }
  func setSummary(_ body: String) {
    lock.lock()
    defer { lock.unlock() }
    summary = body
  }

  func response(for request: URLRequest) -> Response {
    lock.lock()
    defer { lock.unlock() }
    var captured = request
    if captured.httpBody == nil, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4_096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
      }
      captured.httpBody = data
    }
    recorded.append(captured)
    switch request.url?.path {
    case "/v1/info": return Response(body: #"{"single_user":true,"accounts_enabled":false}"#)
    case "/v1/me": return Response(body: #"{"user_id":"local","is_admin":true}"#)
    case "/v1/sessions/session_a": return Response(body: summary)
    case "/v1/sessions/session_a/resources/files": return upload
    case "/v1/sessions/session_a/events": return message
    default: return Response(status: 404)
    }
  }
}

private final class WeakUploadFixture {
  weak var value: UploadFixtureHarness?
  init(_ value: UploadFixtureHarness) { self.value = value }
}

private final class UploadFixtureProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  private static var nextPort = 44_000
  private static var registry: [Int: WeakUploadFixture] = [:]
  static func register() -> Int {
    lock.lock()
    defer { lock.unlock() }
    nextPort += 1
    return nextPort
  }
  static func attach(_ value: UploadFixtureHarness, port: Int) {
    lock.lock()
    defer { lock.unlock() }
    registry[port] = WeakUploadFixture(value)
  }
  static func remove(_ port: Int) {
    lock.lock()
    defer { lock.unlock() }
    registry[port] = nil
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
    if let error = stub.error {
      client?.urlProtocol(self, didFailWithError: URLError(error))
      return
    }
    let response = HTTPURLResponse(
      url: stub.url ?? request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
