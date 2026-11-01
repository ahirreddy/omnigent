import Foundation
import OmnigentCoreFFI

/// Receives the events of one event stream. `ByteSink` conforms; tests record into their own
/// implementation, because the generated `ByteSink` can only be created by the Rust core.
protocol ByteSinkReceiving: Sendable {
  /// The response status and headers, delivered once before any chunk.
  func response(status: UInt16, headers: [HttpHeader])
  /// Body bytes exactly as received.
  func chunk(bytes: Data)
  /// The end of the stream, exactly once, last.
  func finish(failure: ConnectionFailure?)
}

/// Receives the events of one WebSocket. `MessageSink` conforms for the same reason as
/// ``ByteSinkReceiving``.
protocol MessageSinkReceiving: Sendable {
  /// The 101 handshake completed.
  func opened()
  /// One inbound data frame.
  func message(message: SocketMessage)
  /// The connection is over, exactly once, last.
  func ended(end: SocketEnd)
}

extension ByteSink: ByteSinkReceiving {}

extension MessageSink: MessageSinkReceiving {}
