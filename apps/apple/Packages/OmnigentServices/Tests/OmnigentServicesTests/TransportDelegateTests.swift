import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentServices

/// Callbacks URLSession can only deliver in a race, sent straight to the delegates. Nothing here
/// resumes a task, so nothing reaches the network.
@Suite("Transport delegates") struct TransportDelegateTests {
  private let session = URLSession(configuration: .ephemeral)

  private func location() throws -> URL {
    try #require(URL(string: "http://127.0.0.1:9/stream"))
  }

  private func response(
    to delegate: EventStreamDelegate, _ response: URLResponse
  ) async throws -> URLSession.ResponseDisposition {
    let task = session.dataTask(with: try location())
    return await withCheckedContinuation { continuation in
      delegate.urlSession(session, dataTask: task, didReceive: response) {
        continuation.resume(returning: $0)
      }
    }
  }

  @Test("A response that arrives after the stream was cancelled is dropped")
  func responseAfterCancel() async throws {
    let sink = RecordingByteSink()
    let delegate = EventStreamDelegate(sink: sink)
    delegate.cancel()
    let plain = URLResponse(
      url: try location(), mimeType: nil, expectedContentLength: 0, textEncodingName: nil)

    #expect(try await response(to: delegate, plain) == .cancel)
    #expect(sink.snapshot.isEmpty)
  }

  @Test("A frame of a kind this transport doesn't know ends the socket once")
  func unknownFrame() throws {
    let sink = RecordingMessageSink()
    let delegate = SocketDelegate(sink: sink)
    let task = session.webSocketTask(with: try #require(URL(string: "ws://127.0.0.1:9/socket")))

    delegate.deliver(nil, from: task)
    delegate.deliver(.text(text: "too late"), from: task)

    #expect(
      sink.snapshot == [
        .ended(.failed(failure: .other(message: "Unsupported WebSocket frame type.")))
      ])
  }
}

/// Answers that aren't HTTP at all, with no network: a `data:` URL answers from its own text.
@Suite("Non-HTTP answers") struct NonHTTPTransportTests {
  private let dataURL = "data:text/plain,hello"

  @Test("An event stream that gets a non-HTTP answer fails once and delivers nothing else")
  func eventStream() async throws {
    let sink = RecordingByteSink()
    let handle = try URLSessionEventStreamTransport().startStream(
      request: HttpRequest(method: "GET", url: dataURL, headers: [], body: nil), sink: sink)
    defer { handle.cancel() }

    #expect(await eventually { !sink.snapshot.isEmpty })

    #expect(sink.snapshot.count == 1)
    guard case .finish(.other(let message)?) = sink.snapshot.first else {
      Issue.record("expected the stream to fail, got \(sink.snapshot)")
      return
    }
    #expect(message.contains("Expected an HTTP response"))
  }
}
