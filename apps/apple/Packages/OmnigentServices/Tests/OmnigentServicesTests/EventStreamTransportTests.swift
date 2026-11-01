import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentServices

@Suite struct EventStreamTransportTests {
  private func request(_ url: String) -> HttpRequest {
    HttpRequest(
      method: "GET", url: url,
      headers: [HttpHeader(name: "Accept", value: "text/event-stream")], body: nil)
  }

  @Test func deliversResponseThenChunksExactlyAndFinishes() async throws {
    let (chunks, continuation) = AsyncStream.makeStream(of: Data.self)
    let server = try await MockHTTPServer.start { _ in
      .streaming(
        status: 200, headers: ["Content-Type": "text/event-stream"], chunks: chunks)
    }
    defer { server.stop() }
    let sink = RecordingByteSink()

    _ = try URLSessionEventStreamTransport().startStream(
      request: request(server.url(for: "/v1/sessions/s1/stream")), sink: sink)

    // Split one SSE event across chunk boundaries and include a multi-byte UTF-8 character.
    let pieces = [
      Data("data: {\"text\":\"caf".utf8),
      Data("é\"}\n\n".utf8),
      Data("data: second\n\n".utf8),
    ]
    let expected = pieces.reduce(into: Data()) { $0.append($1) }
    for piece in pieces {
      continuation.yield(piece)
    }
    continuation.finish()

    #expect(
      await eventually { sink.snapshot.contains { if case .finish = $0 { true } else { false } } })

    let events = sink.snapshot
    guard case .response(let status, let headers) = events.first else {
      Issue.record("first event was not a response: \(events)")
      return
    }
    #expect(status == 200)
    #expect(
      headers.contains {
        $0.name.lowercased() == "content-type" && $0.value.contains("text/event-stream")
      })
    #expect(sink.body == expected)
    #expect(events.last == .finish(nil))
    let responses = events.filter { if case .response = $0 { true } else { false } }
    #expect(responses.count == 1)
  }

  @Test func redirectIsDeliveredAsTheResponseAndNotFollowed() async throws {
    let server = try await MockHTTPServer.start { request in
      switch request.path {
      case "/start":
        .complete(status: 302, headers: ["Location": "/elsewhere"], body: Data())
      default:
        .complete(status: 200, headers: [:], body: Data("followed".utf8))
      }
    }
    defer { server.stop() }
    let sink = RecordingByteSink()

    _ = try URLSessionEventStreamTransport().startStream(
      request: request(server.url(for: "/start")), sink: sink)

    #expect(await eventually { sink.snapshot.last == .finish(nil) })
    guard case .response(let status, let headers) = sink.snapshot.first else {
      Issue.record("expected a response first: \(sink.snapshot)")
      return
    }
    #expect(status == 302)
    #expect(headers.contains { $0.name.lowercased() == "location" && $0.value == "/elsewhere" })
    #expect(server.requests.map(\.path) == ["/start"])
  }

  @Test func serverErrorStatusIsAResponseNotAFailure() async throws {
    let server = try await MockHTTPServer.start { _ in
      .complete(status: 500, headers: [:], body: Data("boom".utf8))
    }
    defer { server.stop() }
    let sink = RecordingByteSink()

    _ = try URLSessionEventStreamTransport().startStream(
      request: request(server.url(for: "/fail")), sink: sink)

    #expect(await eventually { sink.snapshot.last == .finish(nil) })
    guard case .response(let status, _) = sink.snapshot.first else {
      Issue.record("expected a response first: \(sink.snapshot)")
      return
    }
    #expect(status == 500)
    #expect(sink.body == Data("boom".utf8))
  }

  @Test func connectionRefusedFinishesWithOfflineAndNoResponse() async throws {
    let url = try await closedPortURL(path: "/v1/sessions/s1/stream")
    let sink = RecordingByteSink()

    _ = try URLSessionEventStreamTransport().startStream(request: request(url), sink: sink)

    #expect(await eventually { sink.snapshot.last != nil })
    guard case .finish(let failure) = sink.snapshot.last else {
      Issue.record("expected a finish event: \(sink.snapshot)")
      return
    }
    guard case .offline = failure else {
      Issue.record("expected offline, got \(String(describing: failure))")
      return
    }
    #expect(sink.snapshot.count == 1)
  }

  @Test func cancelStopsDeliveryAndFinishIsNotDelivered() async throws {
    let (chunks, continuation) = AsyncStream.makeStream(of: Data.self)
    let server = try await MockHTTPServer.start { _ in
      .streaming(status: 200, headers: [:], chunks: chunks)
    }
    defer { server.stop() }
    let sink = RecordingByteSink()

    let handle = try URLSessionEventStreamTransport().startStream(
      request: request(server.url(for: "/stream")), sink: sink)
    continuation.yield(Data("before\n\n".utf8))
    #expect(await eventually { sink.body == Data("before\n\n".utf8) })

    handle.cancel()
    continuation.yield(Data("after\n\n".utf8))
    continuation.finish()
    // Give any late callback the chance to arrive, so the assertions below are meaningful.
    try await Task.sleep(for: .milliseconds(300))

    #expect(sink.body == Data("before\n\n".utf8))
    #expect(!sink.snapshot.contains { if case .finish = $0 { true } else { false } })
  }

  @Test func invalidURLFailsToStart() {
    #expect(throws: TransportError.self) {
      _ = try URLSessionEventStreamTransport().startStream(
        request: HttpRequest(method: "GET", url: "not a url", headers: [], body: nil),
        sink: RecordingByteSink())
    }
  }

  @Test func connectionFailureMapsAuthenticationDemandsAndTimeouts() {
    #expect(
      TransportErrorMapping.connectionFailure(from: URLError(.userAuthenticationRequired))
        .isAuthenticationRequired)
    #expect(
      TransportErrorMapping.connectionFailure(from: URLError(.userCancelledAuthentication))
        .isAuthenticationRequired)
    #expect(TransportErrorMapping.connectionFailure(from: URLError(.timedOut)).isTimeout)
    #expect(TransportErrorMapping.connectionFailure(from: URLError(.cancelled)) == .cancelled)
    #expect(TransportErrorMapping.connectionFailure(from: URLError(.secureConnectionFailed)).isTLS)
  }
}

extension ConnectionFailure {
  fileprivate var isAuthenticationRequired: Bool {
    if case .authenticationRequired = self { return true }
    return false
  }

  fileprivate var isTimeout: Bool {
    if case .timeout = self { return true }
    return false
  }

  fileprivate var isTLS: Bool {
    if case .tls = self { return true }
    return false
  }
}
