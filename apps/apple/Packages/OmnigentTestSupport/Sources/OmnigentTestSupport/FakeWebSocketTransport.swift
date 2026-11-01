public import Foundation
public import OmnigentCoreFFI
import Synchronization

/// A socket opened on a ``FakeWebSocketTransport``.
public struct OpenedWebSocket: Sendable {
  /// The upgrade request the core asked to open.
  public let request: HttpRequest
  /// The sink the test drives: call `opened`, `message` and `ended` on it.
  public let sink: MessageSink
  /// The handle the core sends and closes through.
  public let handle: FakeWebSocketHandle
}

/// `WebSocketTransport` that records connects and hands each sink to the test.
public final class FakeWebSocketTransport: WebSocketTransport, Sendable {
  private let connects = Rendezvous<OpenedWebSocket>()
  private let recorded = Mutex<[OpenedWebSocket]>([])
  private let connectFailure = Mutex<TransportError?>(nil)

  /// Creates a fake with no failures configured.
  public init() {}

  /// Every socket opened so far, in order.
  public var openedSockets: [OpenedWebSocket] {
    recorded.withLock { $0 }
  }

  /// Makes every later `connect` fail with `error`.
  public func failConnects(with error: TransportError?) {
    connectFailure.withLock { $0 = error }
  }

  /// Waits for the next socket the core opens, and returns its request and sink.
  public func waitForConnect() async -> (HttpRequest, MessageSink) {
    let opened = await connects.next()
    return (opened.request, opened.sink)
  }

  /// Waits for the next socket the core opens, with its handle.
  public func waitForOpenedSocket() async -> OpenedWebSocket {
    await connects.next()
  }

  /// Records the socket and hands its sink to the test.
  /// - Parameters:
  ///   - request: The upgrade request.
  ///   - sink: The socket's event sink.
  /// - Returns: The fake handle for the socket.
  /// - Throws: The configured connect failure, if any.
  public func openSocket(request: HttpRequest, sink: MessageSink) throws(TransportError)
    -> any WebSocketHandle
  {
    if let failure = connectFailure.withLock({ $0 }) {
      throw failure
    }
    let handle = FakeWebSocketHandle()
    let opened = OpenedWebSocket(request: request, sink: sink, handle: handle)
    recorded.withLock { $0.append(opened) }
    connects.push(opened)
    return handle
  }
}

/// Records what the core sent and closed on one fake socket.
public final class FakeWebSocketHandle: WebSocketHandle, Sendable {
  /// One recorded close call.
  public struct Close: Sendable, Equatable {
    /// The close code.
    public let code: UInt16
    /// The close reason.
    public let reason: String
  }

  private struct State {
    var sent: [String] = []
    var sentBinaries: [Data] = []
    var closes: [Close] = []
    var sendFailure: TransportError?
  }

  private let state = Mutex(State())

  /// Creates a handle with nothing sent.
  public init() {}

  /// The text frames the core sent, in order.
  public var sentTexts: [String] {
    state.withLock { $0.sent }
  }

  /// The binary frames the core sent, in order.
  public var sentBinaries: [Data] {
    state.withLock { $0.sentBinaries }
  }

  /// The close calls the core made, in order.
  public var closes: [Close] {
    state.withLock { $0.closes }
  }

  /// Makes every later `sendText` fail with `error`.
  public func failSends(with error: TransportError?) {
    state.withLock { $0.sendFailure = error }
  }

  /// Records the frame, or throws the configured send failure.
  /// - Parameter text: The frame's text.
  /// - Throws: The configured send failure, if any.
  public func sendText(text: String) throws(TransportError) {
    let failure = state.withLock { state -> TransportError? in
      if let failure = state.sendFailure {
        return failure
      }
      state.sent.append(text)
      return nil
    }
    if let failure {
      throw failure
    }
  }

  /// Records the binary frame, or throws the configured send failure.
  /// - Parameter bytes: The frame's bytes.
  /// - Throws: The configured send failure, if any.
  public func sendBinary(bytes: Data) throws(TransportError) {
    let failure = state.withLock { state -> TransportError? in
      if let failure = state.sendFailure {
        return failure
      }
      state.sentBinaries.append(bytes)
      return nil
    }
    if let failure {
      throw failure
    }
  }

  /// Records the close call.
  /// - Parameters:
  ///   - code: The close code.
  ///   - reason: The close reason.
  public func close(code: UInt16, reason: String) {
    state.withLock { $0.closes.append(Close(code: code, reason: reason)) }
  }
}
