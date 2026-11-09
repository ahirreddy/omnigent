import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Synchronization
import Testing

@testable import OmnigentServices

/// Polls `condition` until it holds or `timeout` passes.
/// - Returns: Whether the condition held before the timeout.
@discardableResult
func eventually(
  timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if condition() { return true }
    do {
      try await Task.sleep(for: .milliseconds(10))
    } catch {
      // Cancelling the test ends the wait; the final check below still reports the state.
      break
    }
  }
  return condition()
}

/// Runs `body` and returns the error it threw. Records an issue and returns nil when it does not
/// throw.
func thrownError(_ body: () throws -> Void) -> (any Error)? {
  do {
    try body()
  } catch {
    return error
  }
  Issue.record("expected the call to throw")
  return nil
}

/// A string holding half of a surrogate pair, which Swift can't write directly.
func loneSurrogateString() -> Any {
  // swiftlint:disable:next legacy_objc_type
  unsafe NSString(characters: [unichar(0xD800)], length: 1)
}

/// Records every event of one event stream, in order.
final class RecordingByteSink: ByteSinkReceiving, Sendable {
  enum Event: Sendable, Equatable {
    case response(status: UInt16, headers: [HttpHeader])
    case chunk(Data)
    case finish(ConnectionFailure?)
  }

  private let events = Mutex<[Event]>([])

  var snapshot: [Event] {
    events.withLock { $0 }
  }

  /// The concatenated body bytes delivered so far.
  var body: Data {
    snapshot.reduce(into: Data()) { body, event in
      if case .chunk(let bytes) = event {
        body.append(bytes)
      }
    }
  }

  func response(status: UInt16, headers: [HttpHeader]) {
    events.withLock { $0.append(.response(status: status, headers: headers)) }
  }

  func chunk(bytes: Data) {
    events.withLock { $0.append(.chunk(bytes)) }
  }

  func finish(failure: ConnectionFailure?) {
    events.withLock { $0.append(.finish(failure)) }
  }
}

/// Records every event of one WebSocket, in order.
final class RecordingMessageSink: MessageSinkReceiving, Sendable {
  enum Event: Sendable, Equatable {
    case opened
    case message(SocketMessage)
    case ended(SocketEnd)
  }

  private let events = Mutex<[Event]>([])

  var snapshot: [Event] {
    events.withLock { $0 }
  }

  func opened() {
    events.withLock { $0.append(.opened) }
  }

  func message(message: SocketMessage) {
    events.withLock { $0.append(.message(message)) }
  }

  func ended(end: SocketEnd) {
    events.withLock { $0.append(.ended(end)) }
  }
}

/// A `file://`-free loopback URL for a port that nothing listens on.
func closedPortURL(path: String) async throws -> String {
  let server = try await MockHTTPServer.start { _ in
    .complete(status: 200, headers: [:], body: Data())
  }
  let port = server.port
  server.stop()
  // Give the listener a moment to release the port, so the connection is refused.
  try await Task.sleep(for: .milliseconds(50))
  return "http://127.0.0.1:\(port)\(path)"
}
