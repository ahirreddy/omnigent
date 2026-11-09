#if os(macOS)
  public import Foundation
  import Network
  import OSLog
  import Synchronization

  /// Why a loopback redirect wait failed.
  public enum LoopbackRedirectError: Error, Sendable, Equatable {
    /// ``LoopbackRedirectListener/start(path:)`` was already called.
    case alreadyStarted
    /// ``LoopbackRedirectListener/waitForCallback()`` ran before `start(path:)`.
    case notStarted
    /// Another task is already waiting for the callback.
    case alreadyWaiting
    /// The wait was cancelled, by the task or by ``LoopbackRedirectListener/cancel()``.
    case cancelled
    /// The listener could not be created or failed while listening.
    case failed(message: String)
  }

  /// Receives one OAuth redirect on `http://<host>:<port><path>`, where `host` is `127.0.0.1` or
  /// `localhost` (both reach the loopback interface this listens on).
  ///
  /// Used for the desktop sign-in flow: the system browser is sent to the URL from `start(path:)`,
  /// and the browser's redirect to that URL is received here. Only the first `GET` whose path
  /// matches completes the wait, and it is answered with a small page. Other requests get 404, and
  /// other methods get 405. Requests may arrive split across reads.
  public final class LoopbackRedirectListener: Sendable {
    /// Largest request head accepted before the request is rejected with 400.
    static let maximumHeadBytes = 16 * 1024

    private typealias StartContinuation = CheckedContinuation<
      Result<UInt16, LoopbackRedirectError>, Never
    >
    private typealias CallbackContinuation = CheckedContinuation<
      Result<URL, LoopbackRedirectError>, Never
    >

    private struct State {
      var listener: NWListener?
      var path: String?
      var host = "127.0.0.1"
      var startWaiter: StartContinuation?
      var callbackWaiter: CallbackContinuation?
      var outcome: Result<URL, LoopbackRedirectError>?
    }

    /// The waiters that `finish` must resume, taken out of the state under the lock.
    private struct Waiters {
      var listener: NWListener?
      var callback: CallbackContinuation?
      var start: StartContinuation?
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "ai.omnigent.loopback-redirect")
    private let makeListener: @Sendable (NWParameters) throws -> NWListener

    /// Creates a listener. Nothing is bound until ``start(path:)``.
    public convenience init() {
      self.init(makeListener: { try NWListener(using: $0, on: .any) })
    }

    /// Creates a listener that binds through `makeListener`, so a failed bind can be tested.
    init(makeListener: @escaping @Sendable (NWParameters) throws -> NWListener) {
      self.makeListener = makeListener
    }

    /// Waits for the redirect. Cancelling the calling task stops the listener.
    /// - Returns: The full callback URL, including its query.
    /// - Throws: ``LoopbackRedirectError`` when the wait is cancelled, the listener fails, or it
    ///   was never started.
    public func waitForCallback() async throws(LoopbackRedirectError) -> URL {
      let result = await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CallbackContinuation) in
          registerCallbackWaiter(continuation)
        }
      } onCancel: {
        self.cancel()
      }
      return try result.get()
    }

    /// Stops listening and fails any pending wait with ``LoopbackRedirectError/cancelled``.
    /// Has no effect once a callback has completed the wait.
    public func cancel() {
      finish(.failure(.cancelled))
    }

    private func startListener(path: String, continuation: StartContinuation) {
      let parameters = NWParameters.tcp
      parameters.acceptLocalOnly = true
      parameters.requiredInterfaceType = .loopback
      let listener: NWListener
      do {
        listener = try makeListener(parameters)
      } catch {
        continuation.resume(
          returning: .failure(.failed(message: "The listener could not be created: \(error)")))
        return
      }
      let accepted = state.withLock { state -> Bool in
        guard state.listener == nil, state.outcome == nil else { return false }
        state.listener = listener
        state.path = path
        state.startWaiter = continuation
        return true
      }
      guard accepted else {
        listener.cancel()
        continuation.resume(returning: .failure(.alreadyStarted))
        return
      }
      listener.stateUpdateHandler = { [self] newState in listenerStateChanged(newState) }
      listener.newConnectionHandler = { [self] connection in accept(connection) }
      listener.start(queue: queue)
    }

    /// Resolves the callback wait now when the outcome is known, or parks the waiter until it is.
    private func registerCallbackWaiter(_ continuation: CallbackContinuation) {
      let immediate = state.withLock { state -> Result<URL, LoopbackRedirectError>? in
        if let outcome = state.outcome {
          return outcome
        }
        guard state.listener != nil else { return .failure(.notStarted) }
        guard state.callbackWaiter == nil else { return .failure(.alreadyWaiting) }
        state.callbackWaiter = continuation
        return nil
      }
      if let immediate {
        continuation.resume(returning: immediate)
      }
    }

    /// Completes the wait once and stops the listener. Later calls are ignored.
    private func finish(_ outcome: Result<URL, LoopbackRedirectError>) {
      let waiters = state.withLock { state -> Waiters? in
        guard state.outcome == nil else { return nil }
        state.outcome = outcome
        let waiters = Waiters(
          listener: state.listener, callback: state.callbackWaiter, start: state.startWaiter)
        state.callbackWaiter = nil
        state.startWaiter = nil
        return waiters
      }
      guard let waiters else { return }
      waiters.listener?.stateUpdateHandler = nil
      waiters.listener?.newConnectionHandler = nil
      waiters.listener?.cancel()
      waiters.start?.resume(returning: .failure(.cancelled))
      waiters.callback?.resume(returning: outcome)
    }

    func listenerStateChanged(_ newState: NWListener.State) {
      switch newState {
      case .ready:
        listenerBecameReady()
      case .failed(let error):
        let message = "The listener failed: \(error)"
        servicesLogger.error("\(message)")
        let startWaiter = state.withLock { state -> StartContinuation? in
          let waiter = state.startWaiter
          state.startWaiter = nil
          return waiter
        }
        startWaiter?.resume(returning: .failure(.failed(message: message)))
        finish(.failure(.failed(message: message)))
      default:
        return
      }
    }

    /// Hands the bound port to the waiting `start(path:)`.
    private func listenerBecameReady() {
      let (port, startWaiter) = state.withLock { state -> (UInt16?, StartContinuation?) in
        let waiter = state.startWaiter
        state.startWaiter = nil
        return (state.listener?.port?.rawValue, waiter)
      }
      guard let port else {
        finish(.failure(.failed(message: "The listener is ready without a port.")))
        return
      }
      startWaiter?.resume(returning: .success(port))
    }

    func accept(_ connection: NWConnection) {
      let accepted = LoopbackConnection(connection)
      let isOpen = state.withLock { $0.outcome == nil }
      guard isOpen else {
        connection.cancel()
        return
      }
      connection.start(queue: queue)
      receive(accepted, buffer: Data())
    }

    private func receive(_ accepted: LoopbackConnection, buffer: Data) {
      accepted.connection.receive(
        minimumIncompleteLength: 1, maximumLength: 8192,
        completion: receiveCompletion(accepted, buffer: buffer))
    }

    /// Accumulates received bytes until the request head is complete, then handles it.
    func receiveCompletion(
      _ accepted: LoopbackConnection, buffer: Data
    ) -> @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void {
      { [self] content, _, isComplete, error in
        var buffer = buffer
        if let content {
          buffer.append(content)
        }
        if let error {
          servicesLogger.error("Loopback redirect connection failed: \(error)")
          accepted.connection.cancel()
          return
        }
        if let head = Self.requestLine(in: buffer) {
          handle(head, on: accepted)
          return
        }
        if buffer.count > Self.maximumHeadBytes {
          respond(on: accepted, status: 400, reason: "Bad Request", body: "Request too large.")
          return
        }
        if isComplete {
          accepted.connection.cancel()
          return
        }
        receive(accepted, buffer: buffer)
      }
    }

    private func handle(_ line: RequestLine, on accepted: LoopbackConnection) {
      let expected = state.withLock { $0.path }
      let (port, host) = state.withLock { ($0.listener?.port?.rawValue, $0.host) }
      switch Self.decision(for: line, expectedPath: expected, port: port, host: host) {
      case .refuse(let status, let reason, let body):
        respond(on: accepted, status: status, reason: reason, body: body)
      case .complete(let url):
        respond(
          on: accepted, status: 200, reason: "OK",
          body: "<!doctype html><title>Omnigent</title>"
            + "<p>Sign-in complete. You can close this window.</p>")
        finish(.success(url))
      }
    }

    private func respond(
      on accepted: LoopbackConnection, status: Int, reason: String, body: String
    ) {
      let payload = Data(body.utf8)
      let head =
        "HTTP/1.1 \(status) \(reason)\r\n"
        + "Content-Type: text/html; charset=utf-8\r\n"
        + "Content-Length: \(payload.count)\r\n"
        + "Cache-Control: no-store\r\n"
        + "Connection: close\r\n\r\n"
      accepted.connection.send(
        content: Data(head.utf8) + payload,
        completion: .contentProcessed(sendCompletion(accepted)))
    }

    /// Logs a failed response write, then closes the connection.
    func sendCompletion(_ accepted: LoopbackConnection) -> @Sendable (NWError?) -> Void {
      { error in
        if let error {
          servicesLogger.error("Loopback redirect response failed: \(error)")
        }
        accepted.connection.cancel()
      }
    }
  }

  /// Owns one accepted connection. `NWConnection` is not `Sendable`, but this wrapper only calls
  /// its thread-safe `receive`, `send`, and `cancel`, and it is created and used only inside the
  /// listener's callbacks.
  final class LoopbackConnection: @unchecked Sendable {
    let connection: NWConnection

    init(_ connection: NWConnection) {
      self.connection = connection
    }
  }

  extension LoopbackRedirectListener {
    /// What a complete request head leads to.
    enum RequestDecision: Equatable {
      /// The redirect arrived: answer with the sign-in page and end the wait.
      case complete(URL)
      /// Answer with this error and keep waiting.
      case refuse(status: Int, reason: String, body: String)
    }

    /// Decides how to answer a request.
    /// - Parameters:
    ///   - line: The parsed request line.
    ///   - expectedPath: The redirect path, without a query.
    ///   - port: The bound port.
    ///   - host: The host the redirect URL names.
    /// - Returns: The decision.
    static func decision(
      for line: RequestLine, expectedPath: String?, port: UInt16?, host: String
    ) -> RequestDecision {
      let malformed = RequestDecision.refuse(
        status: 400, reason: "Bad Request", body: "Malformed request.")
      guard !line.method.isEmpty else { return malformed }
      guard line.method == "GET" else {
        return .refuse(status: 405, reason: "Method Not Allowed", body: "Method not allowed.")
      }
      let requestPath = line.target.split(separator: "?", maxSplits: 1).first.map(String.init)
      guard requestPath == expectedPath else {
        return .refuse(status: 404, reason: "Not Found", body: "Not found.")
      }
      guard case .success(let url) = callbackURL(host: host, port: port, target: line.target) else {
        return malformed
      }
      return .complete(url)
    }

    /// The URL the browser reached, or was told to reach.
    /// - Parameters:
    ///   - host: The host the redirect URL names.
    ///   - port: The bound port.
    ///   - target: The path and query.
    /// - Returns: The URL, or a failure when no port is bound.
    static func callbackURL(
      host: String, port: UInt16?, target: String
    ) -> Result<URL, LoopbackRedirectError> {
      guard let port, let url = URL(string: "http://\(host):\(port)\(target)") else {
        return .failure(.failed(message: "The redirect URL could not be formed for \(target)."))
      }
      return .success(url)
    }

    /// The method and target of the request line, once the head is complete.
    struct RequestLine: Equatable {
      let method: String
      let target: String
    }

    /// Parses the request line once the head (through the blank line) has fully arrived. A head
    /// without a parsable request line yields an empty method, which is answered with 400.
    static func requestLine(in buffer: Data) -> RequestLine? {
      let terminator = Data("\r\n\r\n".utf8)
      guard buffer.firstRange(of: terminator) != nil else { return nil }
      let malformed = RequestLine(method: "", target: "")
      guard let head = String(bytes: buffer, encoding: .utf8),
        let firstLine = head.components(separatedBy: "\r\n").first
      else {
        return malformed
      }
      let parts = firstLine.split(separator: " ")
      guard parts.count == 3 else {
        return malformed
      }
      return RequestLine(method: String(parts[0]), target: String(parts[1]))
    }
  }

  extension LoopbackRedirectListener {
    /// Binds an ephemeral port on the loopback interface.
    /// - Parameters:
    ///   - path: The redirect path, starting with `/`, for example `/oauth/callback`.
    ///   - host: The host the redirect URL names: `127.0.0.1`, or `localhost` for an
    ///     authorization server that registers `http://localhost` (Databricks).
    /// - Returns: The redirect URL to register with the authorization server.
    /// - Throws: ``LoopbackRedirectError`` when the listener cannot start or was cancelled.
    public func start(path: String, host: String = "127.0.0.1") async throws(LoopbackRedirectError)
      -> URL
    {
      guard path.hasPrefix("/") else {
        throw .failed(message: "The redirect path must start with /: \(path)")
      }
      guard host == "127.0.0.1" || host == "localhost" else {
        throw .failed(message: "The redirect host must be 127.0.0.1 or localhost: \(host)")
      }
      state.withLock { $0.host = host }
      let result = await withCheckedContinuation { (continuation: StartContinuation) in
        startListener(path: path, continuation: continuation)
      }
      return try Self.callbackURL(host: host, port: result.get(), target: path).get()
    }
  }
#endif
