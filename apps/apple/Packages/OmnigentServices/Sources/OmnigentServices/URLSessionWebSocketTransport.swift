public import Foundation
import OSLog
public import OmnigentCoreFFI
import Synchronization

/// `WebSocketTransport` host implementation backed by `URLSessionWebSocketTask`.
///
/// Each socket gets its own ephemeral session and delegate, invalidated when the socket ends.
/// Redirects are refused, so a non-101 answer surfaces as a handshake rejection carrying its
/// status. Inbound messages are capped at 8 MiB. There is no timeout: the core's silence
/// watchdog owns liveness.
public final class URLSessionWebSocketTransport: WebSocketTransport, Sendable {
  /// Largest inbound message accepted, in bytes.
  static let maximumMessageSize = 8 * 1024 * 1024

  /// Creates a transport.
  public init() {}

  /// Starts a WebSocket upgrade.
  /// - Parameters:
  ///   - request: The upgrade request built by the core. Headers are copied as given.
  ///   - sink: Receives the open, message and end events.
  /// - Returns: A handle for sending and closing.
  /// - Throws: `TransportError` when the upgrade cannot be started.
  public func openSocket(
    request: HttpRequest, sink: MessageSink
  ) throws(TransportError) -> any WebSocketHandle {
    try startSocket(request: request, sink: sink)
  }

  /// An ephemeral configuration with cookies and caching disabled and no request timeout.
  static func makeSocketConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = unlimitedInterval
    configuration.timeoutIntervalForResource = unlimitedInterval
    configuration.waitsForConnectivity = false
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return configuration
  }

  /// Starts the upgrade, delivering events to any receiver. Shared by the public `connect`.
  func startSocket(
    request: HttpRequest, sink: any MessageSinkReceiving
  ) throws(TransportError) -> any WebSocketHandle {
    let urlRequest = try URLSessionHttpTransport.makeURLRequest(request)
    let delegate = SocketDelegate(sink: sink)
    // URLSession retains its delegate until the session is invalidated, which every end path
    // does, so a strong reference is intended here.
    let session = URLSession(
      configuration: Self.makeSocketConfiguration(),
      delegate: delegate,
      delegateQueue: delegate.queue)
    let task = session.webSocketTask(with: urlRequest)
    task.maximumMessageSize = Self.maximumMessageSize
    task.resume()
    return SocketHandleImpl(session: session, task: task)
  }
}

/// The interval used for "no timeout": one year, which URLSession treats as effectively
/// unbounded for these long-lived requests.
private let unlimitedInterval: TimeInterval = 60 * 60 * 24 * 365

/// Sends frames and closes one socket.
private final class SocketHandleImpl: WebSocketHandle, Sendable {
  private let session: URLSession
  private let task: URLSessionWebSocketTask

  init(session: URLSession, task: URLSessionWebSocketTask) {
    self.session = session
    self.task = task
  }

  func sendText(text: String) async throws(TransportError) {
    do {
      try await task.send(.string(text))
    } catch {
      throw TransportErrorMapping.map(error)
    }
  }

  func sendBinary(bytes: Data) async throws(TransportError) {
    do {
      try await task.send(.data(bytes))
    } catch {
      throw TransportErrorMapping.map(error)
    }
  }

  func close(code: UInt16, reason: String) {
    // CloseCode is an imported C enum and takes any raw value, so application codes pass through.
    let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: Int(code)) ?? .invalid
    task.cancel(with: closeCode, reason: reason.isEmpty ? nil : Data(reason.utf8))
  }
}

/// Routes one socket's delegate callbacks to its sink.
///
/// Every callback, including receive completions, is posted to `queue` in arrival order, so the
/// sink sees opened, then messages, then ended, with no reordering between URLSession threads.
final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate,
  Sendable
{
  struct State {
    var opened = false
    var ended = false
  }

  let sink: any MessageSinkReceiving
  let queue: OperationQueue
  private let state = Mutex(State())

  init(sink: any MessageSinkReceiving) {
    self.sink = sink
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.name = "ai.omnigent.websocket"
    self.queue = queue
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    queue.addOperation { [self] in
      let deliver = state.withLock { state -> Bool in
        guard !state.opened, !state.ended else { return false }
        state.opened = true
        return true
      }
      guard deliver else { return }
      sink.opened()
      receiveNext(webSocketTask)
    }
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    let code = UInt16(truncatingIfNeeded: closeCode.rawValue)
    // Lossy decoding keeps the close reason visible even if the server sent invalid UTF-8.
    // swiftlint:disable:next optional_data_string_conversion
    let text = String(decoding: reason ?? Data(), as: UTF8.self)
    queue.addOperation { [self] in
      end(.closed(code: code, reason: text), session: session)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    let response = task.response as? HTTPURLResponse
    queue.addOperation { [self] in
      let opened = state.withLock { $0.opened }
      if !opened, let response, response.statusCode != 101 {
        logRefusedRequest(task.originalRequest, status: response.statusCode)
        end(
          .handshakeRejected(status: UInt16(truncatingIfNeeded: response.statusCode)),
          session: session)
        return
      }
      let failure =
        error.map(TransportErrorMapping.connectionFailure(from:))
        ?? .other(message: "The WebSocket ended without a close frame.")
      end(.failed(failure: failure), session: session)
    }
  }

  /// Refuses every redirect, so a 3xx surfaces as a handshake rejection.
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  /// Receives one frame, delivers it, then waits for the next. A failed receive ends the socket
  /// through `didCompleteWithError` or `didCloseWith`, so it is not handled here.
  private func receiveNext(_ task: URLSessionWebSocketTask) {
    task.receive { [self] result in
      queue.addOperation { [self] in
        switch result {
        case .success(let message):
          deliver(Self.socketMessage(message), from: task)
        case .failure:
          return
        }
      }
    }
  }

  /// Hands one frame to the sink and waits for the next. A frame kind this transport doesn't know
  /// ends the socket.
  /// - Parameters:
  ///   - frame: The frame, or nil for an unknown kind.
  ///   - task: The socket it arrived on.
  func deliver(_ frame: SocketMessage?, from task: URLSessionWebSocketTask) {
    guard !state.withLock({ $0.ended }) else { return }
    guard let frame else {
      end(.failed(failure: .other(message: "Unsupported WebSocket frame type.")), session: nil)
      task.cancel()
      return
    }
    sink.message(message: frame)
    receiveNext(task)
  }

  /// Delivers the end of the socket exactly once and invalidates the session.
  private func end(_ end: SocketEnd, session: URLSession?) {
    let deliver = state.withLock { state -> Bool in
      guard !state.ended else { return false }
      state.ended = true
      return true
    }
    session?.finishTasksAndInvalidate()
    guard deliver else { return }
    sink.ended(end: end)
  }

  /// The core's view of one frame, or nil for a frame kind this transport does not know.
  private static func socketMessage(_ message: URLSessionWebSocketTask.Message) -> SocketMessage? {
    switch message {
    case .string(let text): .text(text: text)
    case .data(let bytes): .binary(bytes: bytes)
    @unknown default: nil
    }
  }
}
