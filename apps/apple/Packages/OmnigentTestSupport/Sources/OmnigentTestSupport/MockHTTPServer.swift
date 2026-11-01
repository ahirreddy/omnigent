public import Foundation
import Network
import OSLog
import Synchronization

/// A local HTTP/1.1 server for tests, bound to an ephemeral port on the loopback interface.
///
/// Each request is recorded, then answered by the handler: either a complete response, or a
/// streaming response whose chunks come from an `AsyncStream` the test controls. Streaming
/// responses use chunked transfer encoding, so a client sees each chunk's boundaries.
public final class MockHTTPServer: Sendable {
  /// A request as received, with header names lowercased.
  public struct Request: Sendable, Equatable {
    /// The HTTP method, upper case.
    public let method: String
    /// The path without the query string.
    public let path: String
    /// The request target, path and query.
    public let target: String
    /// The request headers, with lowercased names.
    public let headers: [String: String]
    /// The request body.
    public let body: Data
  }

  /// How the server answers one request.
  public enum Response: Sendable {
    /// A complete response with a `Content-Length` body.
    case complete(status: Int, headers: [String: String], body: Data)
    /// A chunked response. Each element of `chunks` is written as one HTTP chunk; the response
    /// ends when the stream finishes. Empty elements are skipped, because an empty chunk would
    /// end the response early.
    case streaming(status: Int, headers: [String: String], chunks: AsyncStream<Data>)
  }

  /// Answers one request. Called once per request, on the server's connection task.
  public typealias Handler = @Sendable (Request) -> Response

  /// The bound port on 127.0.0.1.
  public let port: UInt16

  private let listener: NWListener
  private let core: HTTPConnectionCore

  private init(listener: NWListener, port: UInt16, core: HTTPConnectionCore) {
    self.listener = listener
    self.port = port
    self.core = core
  }

  /// Starts a server.
  /// - Parameter handler: Answers each request.
  /// - Returns: The running server. Stop it with ``stop()``.
  /// - Throws: The listener's error when it cannot bind a port.
  public static func start(handler: @escaping Handler) async throws -> MockHTTPServer {
    let core = HTTPConnectionCore(handler: handler)
    let parameters = NWParameters.tcp
    parameters.acceptLocalOnly = true
    parameters.requiredInterfaceType = .loopback
    let listener = try NWListener(using: parameters, on: .any)
    let queue = DispatchQueue(label: "omnigent.test.mock-http")
    let port = try await ListenerStart.start(listener, queue: queue) { connection in
      let box = ConnectionBox(connection)
      Task { await core.serve(box, queue: queue) }
    }
    return MockHTTPServer(listener: listener, port: port, core: core)
  }

  /// An absolute URL for `path` on this server.
  public func url(for path: String) -> String {
    "http://127.0.0.1:\(port)\(path)"
  }

  /// Every request received so far, in arrival order.
  public var requests: [Request] {
    core.recorded.withLock { $0 }
  }

  /// Stops accepting connections. Responses in progress finish.
  public func stop() {
    listener.cancel()
  }
}

/// Serves the connections of one ``MockHTTPServer``. Holds no reference to the listener, so the
/// listener's handler can capture it.
private final class HTTPConnectionCore: Sendable {
  let handler: MockHTTPServer.Handler
  let recorded = Mutex<[MockHTTPServer.Request]>([])

  init(handler: @escaping MockHTTPServer.Handler) {
    self.handler = handler
  }

  func serve(_ box: ConnectionBox, queue: DispatchQueue) async {
    box.connection.start(queue: queue)
    defer { box.connection.cancel() }
    do {
      let request = try await readRequest(box)
      recorded.withLock { $0.append(request) }
      try await write(handler(request), to: box)
    } catch {
      // A client that disconnects mid-response is normal for cancellation tests; log and move on.
      Logger.mockHTTP.debug("Mock HTTP connection ended: \(String(describing: error))")
    }
  }

  private func readRequest(_ box: ConnectionBox) async throws -> MockHTTPServer.Request {
    let terminator = Data("\r\n\r\n".utf8)
    var buffer = Data()
    var headEnd: Data.Index?
    while headEnd == nil {
      let chunk = try await box.receive()
      guard !chunk.isEmpty else {
        throw TestServerError.sendFailed("connection closed before the request head ended")
      }
      buffer.append(chunk)
      headEnd = buffer.range(of: terminator)?.upperBound
    }
    guard let headEnd, let head = String(bytes: buffer[..<headEnd], encoding: .utf8) else {
      throw TestServerError.sendFailed("request head is not UTF-8")
    }
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else {
      throw TestServerError.sendFailed("malformed request line")
    }
    var headers: [String: String] = [:]
    for line in lines where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].lowercased()] =
        line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let contentLength = Int(headers["content-length"] ?? "") ?? 0
    var body = Data(buffer[headEnd...])
    while body.count < contentLength {
      let chunk = try await box.receive()
      guard !chunk.isEmpty else { break }
      body.append(chunk)
    }
    let target = String(requestLine[1])
    let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
    return MockHTTPServer.Request(
      method: String(requestLine[0]).uppercased(), path: path, target: target,
      headers: headers, body: body)
  }

  private func write(_ response: MockHTTPServer.Response, to box: ConnectionBox) async throws {
    switch response {
    case .complete(let status, let headers, let body):
      var allHeaders = headers
      if allHeaders["content-length"] == nil {
        allHeaders["content-length"] = "\(body.count)"
      }
      allHeaders["connection"] = "close"
      try await box.send(Self.headData(status: status, headers: allHeaders) + body)
    case .streaming(let status, let headers, let chunks):
      var allHeaders = headers
      // URLSession holds the head and body of an untyped response while it sniffs the MIME type,
      // so a stream without a Content-Type is not delivered until the response ends. SSE is
      // always typed, so default to it.
      if allHeaders["content-type"] == nil {
        allHeaders["content-type"] = "text/event-stream; charset=utf-8"
      }
      allHeaders["transfer-encoding"] = "chunked"
      allHeaders["connection"] = "close"
      try await box.send(Self.headData(status: status, headers: allHeaders))
      for await chunk in chunks where !chunk.isEmpty {
        var framed = Data(String(chunk.count, radix: 16).utf8)
        framed.append(contentsOf: "\r\n".utf8)
        framed.append(chunk)
        framed.append(contentsOf: "\r\n".utf8)
        try await box.send(framed)
      }
      try await box.send(Data("0\r\n\r\n".utf8))
    }
  }

  private static func headData(status: Int, headers: [String: String]) -> Data {
    var head = "HTTP/1.1 \(status) \(reasonPhrase(for: status))\r\n"
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
      head += "\(name): \(value)\r\n"
    }
    head += "\r\n"
    return Data(head.utf8)
  }

  private static func reasonPhrase(for status: Int) -> String {
    switch status {
    case 200: "OK"
    case 201: "Created"
    case 302: "Found"
    case 400: "Bad Request"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 500: "Internal Server Error"
    default: "Status \(status)"
    }
  }
}

extension Logger {
  /// Logs test-server connection events.
  static let mockHTTP = Logger(subsystem: "ai.omnigent.test-support", category: "mock-http")
}

/// Owns one accepted connection. `NWConnection` is not `Sendable`, but this wrapper only calls
/// its thread-safe `start`, `receive`, `send`, and `cancel`, and each connection is used by a
/// single serving task.
final class ConnectionBox: @unchecked Sendable {
  let connection: NWConnection

  init(_ connection: NWConnection) {
    self.connection = connection
  }

  /// The next bytes received. Empty when the peer closed the connection.
  func receive() async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      connection.receive(
        minimumIncompleteLength: 1, maximumLength: 65_536,
        completion: Self.receiveHandler(continuation))
    }
  }

  private static func receiveHandler(
    _ continuation: CheckedContinuation<Data, any Error>
  ) -> @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void {
    { content, _, _, error in
      if let error {
        continuation.resume(throwing: error)
      } else {
        // Empty data means the peer closed the connection, or sent nothing this round.
        continuation.resume(returning: content ?? Data())
      }
    }
  }

  /// Sends `data` and waits until it has been handed to the network.
  func send(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { continuation in
      connection.send(content: data, completion: .contentProcessed(continuation.resumeOnSend))
    }
  }
}

extension CheckedContinuation where T == Void, E == any Error {
  /// Resumes with success, or with the send error.
  func resumeOnSend(_ error: NWError?) {
    if let error {
      resume(throwing: error)
    } else {
      resume()
    }
  }
}
