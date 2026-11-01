public import Foundation
import Network
import OSLog
import Synchronization

/// A local WebSocket server for tests, built on `NWProtocolWebSocket` so the handshake and
/// framing are the platform's own.
///
/// Text frames it receives are recorded and, when `echoPrefix` is set, echoed back with the
/// prefix. Frames can be pushed to every connected client, and the server can send a close frame
/// with a chosen code and reason.
public final class MockWebSocketServer: Sendable {
  /// The bound port on 127.0.0.1.
  public let port: UInt16

  private let listener: NWListener
  private let core: WebSocketConnectionCore

  private init(listener: NWListener, port: UInt16, core: WebSocketConnectionCore) {
    self.listener = listener
    self.port = port
    self.core = core
  }

  /// Starts a server.
  /// - Parameter echoPrefix: When set, each received text frame is echoed as `prefix + text`.
  /// - Returns: The running server. Stop it with ``stop()``.
  /// - Throws: The listener's error when it cannot bind a port.
  public static func start(echoPrefix: String? = nil) async throws -> MockWebSocketServer {
    let parameters = NWParameters.tcp
    parameters.acceptLocalOnly = true
    parameters.requiredInterfaceType = .loopback
    let webSocket = NWProtocolWebSocket.Options(.version13)
    webSocket.autoReplyPing = true
    parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
    let listener = try NWListener(using: parameters, on: .any)
    let queue = DispatchQueue(label: "omnigent.test.mock-websocket")
    let core = WebSocketConnectionCore(echoPrefix: echoPrefix, queue: queue)
    let port = try await ListenerStart.start(listener, queue: queue) { connection in
      let box = ConnectionBox(connection)
      core.add(box)
      Task { await core.serve(box) }
    }
    return MockWebSocketServer(listener: listener, port: port, core: core)
  }

  /// The `ws://` URL for the server's socket.
  public var url: String {
    "ws://127.0.0.1:\(port)/socket"
  }

  /// Every text frame received so far, in arrival order.
  public var receivedTexts: [String] {
    core.texts.withLock { $0 }
  }

  /// The close codes of every close frame the clients sent, in arrival order. A close frame
  /// without a code is recorded as 1005.
  public var receivedCloseCodes: [UInt16] {
    core.closeCodes.withLock { $0 }
  }

  /// Sends one text frame to every connected client.
  /// - Parameter text: The frame's text.
  /// - Throws: The network error when a frame cannot be sent.
  public func sendText(_ text: String) async throws {
    for box in core.connections.withLock({ $0 }) {
      try await box.sendFrame(opcode: .text, content: Data(text.utf8))
    }
  }

  /// Sends a close frame to every connected client.
  /// - Parameters:
  ///   - code: The application close code.
  ///   - reason: The reason text.
  /// - Throws: The network error when a frame cannot be sent.
  public func sendClose(code: UInt16, reason: String) async throws {
    for box in core.connections.withLock({ $0 }) {
      try await box.sendFrame(opcode: .close, content: Data(reason.utf8), closeCode: code)
    }
  }

  /// Stops accepting connections.
  public func stop() {
    listener.cancel()
  }
}

/// Serves the connections of one ``MockWebSocketServer``. Holds no reference to the listener, so
/// the listener's handler can capture it.
private final class WebSocketConnectionCore: Sendable {
  let echoPrefix: String?
  let queue: DispatchQueue
  let connections = Mutex<[ConnectionBox]>([])
  let texts = Mutex<[String]>([])
  let closeCodes = Mutex<[UInt16]>([])

  init(echoPrefix: String?, queue: DispatchQueue) {
    self.echoPrefix = echoPrefix
    self.queue = queue
  }

  func add(_ box: ConnectionBox) {
    connections.withLock { $0.append(box) }
  }

  func serve(_ box: ConnectionBox) async {
    box.connection.start(queue: queue)
    while true {
      let frame: ConnectionBox.Frame
      do {
        frame = try await box.receiveFrame()
      } catch {
        // A client that closes the socket ends the receive loop; that is how a test connection ends.
        Logger.mockWebSocket.debug("Mock WebSocket receive ended: \(String(describing: error))")
        break
      }
      switch frame.opcode {
      case .text:
        // Lossy decoding: a test server records whatever the client sent.
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: frame.content, as: UTF8.self)
        texts.withLock { $0.append(text) }
        if let echoPrefix {
          guard await echo(echoPrefix + text, on: box) else { return }
        }
      case .close:
        closeCodes.withLock { $0.append(frame.closeCode ?? 1005) }
        box.connection.cancel()
        return
      default:
        continue
      }
    }
    box.connection.cancel()
  }

  /// Sends one echo frame. Returns false, after closing the connection, when the send fails.
  private func echo(_ text: String, on box: ConnectionBox) async -> Bool {
    do {
      try await box.sendFrame(opcode: .text, content: Data(text.utf8))
      return true
    } catch {
      Logger.mockWebSocket.debug("Mock WebSocket echo failed: \(String(describing: error))")
      box.connection.cancel()
      return false
    }
  }
}

extension Logger {
  /// Logs test-server WebSocket events.
  static let mockWebSocket = Logger(
    subsystem: "ai.omnigent.test-support", category: "mock-websocket")
}

extension ConnectionBox {
  /// One received WebSocket message.
  struct Frame: Sendable {
    let opcode: NWProtocolWebSocket.Opcode
    let content: Data
    /// The close code of a close frame, when the frame carried one.
    let closeCode: UInt16?
  }

  /// Receives the next complete message, with its opcode.
  func receiveFrame() async throws -> Frame {
    try await withCheckedThrowingContinuation { continuation in
      connection.receiveMessage { content, context, _, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        let definition = NWProtocolWebSocket.definition
        let metadata = context?.protocolMetadata(definition: definition)
        let webSocketMetadata = metadata as? NWProtocolWebSocket.Metadata
        continuation.resume(
          returning: Frame(
            opcode: webSocketMetadata?.opcode ?? .cont,
            content: content ?? Data(),
            closeCode: webSocketMetadata.flatMap(Self.closeCodeValue)))
      }
    }
  }

  /// Sends one WebSocket frame, optionally with a close code, and waits until it is handed off.
  func sendFrame(
    opcode: NWProtocolWebSocket.Opcode, content: Data, closeCode: UInt16? = nil
  ) async throws {
    let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
    if let closeCode {
      metadata.closeCode = .applicationCode(closeCode)
    }
    let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
    try await withCheckedThrowingContinuation { continuation in
      connection.send(
        content: content,
        contentContext: context,
        isComplete: true,
        completion: .contentProcessed(continuation.resumeOnSend))
    }
  }

  /// The numeric close code carried by a WebSocket metadata value, when there is one.
  fileprivate static func closeCodeValue(_ metadata: NWProtocolWebSocket.Metadata) -> UInt16? {
    switch metadata.closeCode {
    case .protocolCode(let defined):
      defined.rawValue
    case .applicationCode(let code), .privateCode(let code):
      code
    @unknown default:
      nil
    }
  }
}
