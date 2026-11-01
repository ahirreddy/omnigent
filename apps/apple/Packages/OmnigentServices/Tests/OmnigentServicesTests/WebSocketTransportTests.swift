import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentServices

@Suite struct WebSocketTransportTests {
  private func request(_ url: String) -> HttpRequest {
    HttpRequest(
      method: "GET", url: url,
      headers: [HttpHeader(name: "Authorization", value: "Bearer test-token")], body: nil)
  }

  @Test func opensSendsEchoesAndReceivesServerClose() async throws {
    let server = try await MockWebSocketServer.start(echoPrefix: "echo:")
    defer { server.stop() }
    let sink = RecordingMessageSink()

    let handle = try URLSessionWebSocketTransport().startSocket(
      request: request(server.url), sink: sink)

    #expect(await eventually { sink.snapshot.contains(.opened) })
    try await handle.sendText(text: "hello")
    #expect(
      await eventually {
        sink.snapshot.contains(.message(.text(text: "echo:hello")))
      })

    try await server.sendClose(code: 4001, reason: "bye")
    #expect(
      await eventually { sink.snapshot.contains { if case .ended = $0 { true } else { false } } })

    let events = sink.snapshot
    #expect(events.first == .opened)
    #expect(events.last == .ended(.closed(code: 4001, reason: "bye")))
    #expect(events.filter { if case .ended = $0 { true } else { false } }.count == 1)
  }

  @Test func binaryFramesTravelAsDataBothWays() async throws {
    let server = try await MockWebSocketServer.start(echoPrefix: "echo:")
    defer { server.stop() }
    let sink = RecordingMessageSink()

    let handle = try URLSessionWebSocketTransport().startSocket(
      request: request(server.url), sink: sink)

    #expect(await eventually { sink.snapshot.contains(.opened) })
    let input = Data([0x6C, 0x73, 0x0D, 0x00, 0xFF])
    try await handle.sendBinary(bytes: input)
    #expect(
      await eventually {
        sink.snapshot.contains(.message(.binary(bytes: Data("echo:".utf8) + input)))
      })
    #expect(server.receivedBinaries == [input])
    #expect(server.receivedTexts.isEmpty)
  }

  /// A client close ends the socket with exactly one `ended` event. The close frame itself is not
  /// asserted at the server: URLSession can tear the TCP connection down right after the frame,
  /// and the server's receive may report end-of-stream before the frame is surfaced.
  @Test func clientCloseEndsTheSocketExactlyOnce() async throws {
    let server = try await MockWebSocketServer.start()
    defer { server.stop() }
    let sink = RecordingMessageSink()

    let handle = try URLSessionWebSocketTransport().startSocket(
      request: request(server.url), sink: sink)
    #expect(await eventually { sink.snapshot.contains(.opened) })

    handle.close(code: 1001, reason: "client reconnecting")

    #expect(
      await eventually {
        sink.snapshot.contains { event in
          if case .ended = event { return true }
          return false
        }
      })
    let endCount = sink.snapshot.filter { event in
      if case .ended = event { return true }
      return false
    }.count
    #expect(endCount == 1)
  }

  @Test func handshakeRejectionReportsTheHTTPStatus() async throws {
    let server = try await MockHTTPServer.start { _ in
      .complete(status: 403, headers: [:], body: Data("forbidden".utf8))
    }
    defer { server.stop() }
    let sink = RecordingMessageSink()
    let url = server.url(for: "/socket").replacingOccurrences(of: "http://", with: "ws://")

    _ = try URLSessionWebSocketTransport().startSocket(request: request(url), sink: sink)

    #expect(await eventually { sink.snapshot.last != nil })
    #expect(sink.snapshot == [.ended(.handshakeRejected(status: 403))])
    // The upgrade request carries the caller's headers as given.
    #expect(server.requests.first?.headers["authorization"] == "Bearer test-token")
  }

  @Test func redirectIsReportedAsAHandshakeRejection() async throws {
    let server = try await MockHTTPServer.start { _ in
      .complete(status: 302, headers: ["Location": "/elsewhere"], body: Data())
    }
    defer { server.stop() }
    let sink = RecordingMessageSink()
    let url = server.url(for: "/socket").replacingOccurrences(of: "http://", with: "ws://")

    _ = try URLSessionWebSocketTransport().startSocket(request: request(url), sink: sink)

    #expect(await eventually { sink.snapshot.last != nil })
    #expect(sink.snapshot == [.ended(.handshakeRejected(status: 302))])
    #expect(server.requests.map(\.path) == ["/socket"])
  }

  @Test func connectionRefusedEndsAsFailedOffline() async throws {
    let url = try await closedPortURL(path: "/socket")
      .replacingOccurrences(of: "http://", with: "ws://")
    let sink = RecordingMessageSink()

    _ = try URLSessionWebSocketTransport().startSocket(request: request(url), sink: sink)

    #expect(await eventually { sink.snapshot.last != nil })
    guard case .ended(.failed(let failure)) = sink.snapshot.last else {
      Issue.record("expected a failed end, got \(sink.snapshot)")
      return
    }
    guard case .offline = failure else {
      Issue.record("expected offline, got \(failure)")
      return
    }
    #expect(sink.snapshot.count == 1)
  }

  @Test func sendAfterServerCloseThrowsTransportError() async throws {
    let server = try await MockWebSocketServer.start()
    defer { server.stop() }
    let sink = RecordingMessageSink()
    let handle = try URLSessionWebSocketTransport().startSocket(
      request: request(server.url), sink: sink)
    #expect(await eventually { sink.snapshot.contains(.opened) })

    try await server.sendClose(code: 1000, reason: "")
    #expect(
      await eventually { sink.snapshot.contains { if case .ended = $0 { true } else { false } } })

    await #expect(throws: TransportError.self) {
      try await handle.sendText(text: "too late")
    }
  }
}
