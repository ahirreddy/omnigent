public import Foundation
public import OmnigentCoreFFI
import Synchronization

/// `EventStreamTransport` host implementation that streams a response body with `URLSession`.
///
/// Every stream gets its own ephemeral session and delegate. The session is invalidated when
/// the stream ends or is cancelled, so none outlives its request. The delegate runs on a serial
/// queue, so sink callbacks arrive in order. Redirects are refused and every status is delivered
/// as a response. There is no request timeout: the core's stall watchdog owns liveness.
public final class URLSessionEventStreamTransport: EventStreamTransport, Sendable {
  /// Creates a transport.
  public init() {}

  /// Starts a streaming request.
  /// - Parameters:
  ///   - request: The request built by the core.
  ///   - sink: Receives the response, chunks and the final outcome.
  /// - Returns: A handle that cancels the stream.
  /// - Throws: `TransportError` when the request cannot be started.
  public func openStream(request: HttpRequest, sink: ByteSink) throws(TransportError)
    -> any StreamHandle
  {
    try startStream(request: request, sink: sink)
  }

  /// An ephemeral configuration with cookies and caching disabled and no request timeout.
  /// - Returns: A new configuration.
  static func makeStreamConfiguration() -> URLSessionConfiguration {
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

  /// Starts the stream, delivering events to any receiver. Shared by the public `open`.
  func startStream(
    request: HttpRequest, sink: any ByteSinkReceiving
  ) throws(TransportError) -> any StreamHandle {
    let urlRequest = try URLSessionHttpTransport.makeURLRequest(request)
    let delegate = StreamDelegate(sink: sink)
    // URLSession retains its delegate until the session is invalidated, which every end path
    // does, so a strong reference is intended here.
    let session = URLSession(
      configuration: Self.makeStreamConfiguration(),
      delegate: delegate,
      delegateQueue: delegate.queue)
    let task = session.dataTask(with: urlRequest)
    task.resume()
    return StreamHandleImpl(session: session, task: task, control: delegate)
  }
}

/// The interval used for "no timeout": one year, which URLSession treats as effectively
/// unbounded for these long-lived requests.
private let unlimitedInterval: TimeInterval = 60 * 60 * 24 * 365

/// Cancels one stream.
private final class StreamHandleImpl: StreamHandle, Sendable {
  private let session: URLSession
  private let task: URLSessionDataTask
  private let control: StreamDelegate

  init(session: URLSession, task: URLSessionDataTask, control: StreamDelegate) {
    self.session = session
    self.task = task
    self.control = control
  }

  func cancel() {
    control.cancel()
    task.cancel()
    session.invalidateAndCancel()
  }
}

/// Routes one stream's delegate callbacks to its sink. All callbacks run on `queue`, which
/// serializes them, so the sink sees response, chunks and finish in order.
private final class StreamDelegate: NSObject, URLSessionDataDelegate, Sendable {
  struct State {
    var finished = false
    var cancelled = false
  }

  let sink: any ByteSinkReceiving
  let queue: OperationQueue
  private let state = Mutex(State())

  init(sink: any ByteSinkReceiving) {
    self.sink = sink
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.name = "ai.omnigent.event-stream"
    self.queue = queue
  }

  func cancel() {
    state.withLock { $0.cancelled = true }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard isLive() else {
      completionHandler(.cancel)
      return
    }
    guard let http = response as? HTTPURLResponse,
      let status = UInt16(exactly: http.statusCode)
    else {
      completionHandler(.cancel)
      finish(
        with: .other(message: "Expected an HTTP response, got \(type(of: response))"),
        session: session)
      return
    }
    logRefusedRequest(method: "GET", url: http.url, status: http.statusCode)
    completionHandler(.allow)
    sink.response(status: status, headers: URLSessionHttpTransport.headers(from: http))
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard isLive() else { return }
    sink.chunk(bytes: data)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    finish(with: error.map(TransportErrorMapping.connectionFailure(from:)), session: session)
  }

  /// Refuses every redirect, so the 3xx is delivered as the response.
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  /// Whether callbacks may still reach the sink: not cancelled and not finished.
  private func isLive() -> Bool {
    state.withLock { !$0.cancelled && !$0.finished }
  }

  /// Delivers the end of the stream exactly once, unless the stream was cancelled. Invalidates
  /// the session, which releases this delegate.
  private func finish(with failure: ConnectionFailure?, session: URLSession) {
    let deliver = state.withLock { state -> Bool in
      guard !state.finished else { return false }
      state.finished = true
      return !state.cancelled
    }
    session.finishTasksAndInvalidate()
    guard deliver else { return }
    sink.finish(failure: failure)
  }
}
