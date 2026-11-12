import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentServices

@Suite("Refused request log") struct RefusedRequestLogTests {
  private func request(
    _ url: String, method: String = "GET", headers: [String: String] = [:]
  ) throws -> URLRequest {
    var request = URLRequest(url: try #require(URL(string: url)))
    request.httpMethod = method
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    return request
  }

  @Test("The line says what the server answered, and names query parameters without values")
  func line() throws {
    let refused = try request(
      "https://user:secret@example.test/api/2.0/omnigent/v1/skills?session_id=conv_1&path=%2Fhome",
      headers: [
        "X-Databricks-Omnigent-Slice-Key": "host_a", "X-Databricks-Org-Id": "123",
        "Authorization": "Bearer token-value",
      ])
    let body = Data(
      #"{"error":{"code":"wrong_replica","message":"session runner is on another replica; retry"}}"#
        .utf8)

    let line = try #require(RefusedRequestLine.make(refused, status: 400, body: body))

    #expect(
      line
        == "HTTP 400 GET https://example.test/api/2.0/omnigent/v1/skills key=host_a "
        + "query=session_id,path org=yes body="
        + #"{"error":{"code":"wrong_replica","message":"session runner is on another replica; retry"}}"#
    )
    for hidden in ["conv_1", "%2Fhome", "secret", "token-value", "123"] {
      #expect(!line.contains(hidden), "\(hidden) must not be logged")
    }
  }

  @Test("A request with no key, query, workspace or answer says so")
  func bare() throws {
    let refused = try request("https://example.test/v1/sessions/conv_1/stream")
    #expect(
      RefusedRequestLine.make(refused, status: 503, body: nil)
        == "HTTP 503 GET https://example.test/v1/sessions/conv_1/stream key=none query=none org=no"
    )
    #expect(
      RefusedRequestLine.make(refused, status: 503, body: Data())?.hasSuffix("org=no") == true)
    #expect(RefusedRequestLine.make(nil, status: 500, body: nil)?.contains("<no URL>") == true)
  }

  @Test("Only refusals are logged", arguments: [200, 204, 302, 399])
  func accepted(status: Int) throws {
    let sent = try request("https://example.test/v1/sessions")
    #expect(RefusedRequestLine.make(sent, status: status, body: Data("ok".utf8)) == nil)
  }

  @Test("The answer is cut to 200 characters on one line, whatever its bytes")
  func excerpt() {
    let long = String(repeating: "é", count: 500)
    #expect(RefusedRequestLine.excerpt(of: Data(long.utf8))?.count == 200)
    #expect(
      RefusedRequestLine.excerpt(of: Data("first\r\nsecond\n\nthird".utf8)) == "first second third")
    #expect(RefusedRequestLine.excerpt(of: Data("\n\n".utf8)) == nil)
    #expect(RefusedRequestLine.excerpt(of: Data([0xFF, 0xFE]))?.isEmpty == false)
  }
}

/// A refused stream's answer reaches the sink whole and in order, after its body's start has
/// arrived for the log. Callbacks go straight to the delegate, so nothing reaches the network.
@Suite("Refused event streams") struct RefusedEventStreamTests {
  private let session = URLSession(configuration: .ephemeral)

  private func respond(_ delegate: EventStreamDelegate, status: Int) async throws
    -> URLSessionDataTask
  {
    let url = try #require(URL(string: "http://127.0.0.1:9/v1/sessions/conv_1/stream"))
    let task = session.dataTask(with: url)
    let response = try #require(
      HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [:]))
    let disposition = await withCheckedContinuation { continuation in
      delegate.urlSession(session, dataTask: task, didReceive: response) {
        continuation.resume(returning: $0)
      }
    }
    #expect(disposition == .allow)
    return task
  }

  @Test("A refusal waits for its body, then arrives as response, body and end")
  func heldUntilItsBody() async throws {
    let sink = RecordingByteSink()
    let delegate = EventStreamDelegate(sink: sink)
    let task = try await respond(delegate, status: 400)
    #expect(sink.snapshot.isEmpty, "the status alone is not handed on yet")

    let body = Data(#"{"error":{"code":"wrong_replica"}}"#.utf8)
    delegate.urlSession(session, dataTask: task, didReceive: body)
    #expect(sink.snapshot.isEmpty)
    delegate.urlSession(session, task: task, didCompleteWithError: nil)

    #expect(
      sink.snapshot == [.response(status: 400, headers: []), .chunk(body), .finish(nil)])
  }

  @Test("A refusal with no body still arrives when the response ends")
  func emptyBody() async throws {
    let sink = RecordingByteSink()
    let delegate = EventStreamDelegate(sink: sink)
    let task = try await respond(delegate, status: 503)
    delegate.urlSession(session, task: task, didCompleteWithError: nil)
    #expect(sink.snapshot == [.response(status: 503, headers: []), .finish(nil)])
  }

  @Test("A refusal that keeps sending is handed on once the log has enough, then streams")
  func longBody() async throws {
    let sink = RecordingByteSink()
    let delegate = EventStreamDelegate(sink: sink)
    let task = try await respond(delegate, status: 500)
    let first = Data(repeating: 0x61, count: RefusedRequestLine.bodyLimit * 4)
    let second = Data("more".utf8)

    delegate.urlSession(session, dataTask: task, didReceive: first)
    #expect(sink.snapshot == [.response(status: 500, headers: []), .chunk(first)])
    delegate.urlSession(session, dataTask: task, didReceive: second)
    #expect(sink.snapshot.last == .chunk(second))
  }

  @Test("An accepted stream is handed on at once, and a cancelled refusal never is")
  func acceptedAndCancelled() async throws {
    let accepted = RecordingByteSink()
    _ = try await respond(EventStreamDelegate(sink: accepted), status: 200)
    #expect(accepted.snapshot == [.response(status: 200, headers: [])])

    let cancelled = RecordingByteSink()
    let delegate = EventStreamDelegate(sink: cancelled)
    let task = try await respond(delegate, status: 400)
    delegate.cancel()
    delegate.urlSession(session, dataTask: task, didReceive: Data("late".utf8))
    delegate.urlSession(session, task: task, didCompleteWithError: nil)
    #expect(cancelled.snapshot.isEmpty)
  }
}
