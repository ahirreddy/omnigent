internal import CryptoKit
internal import Foundation

/// The DevTools gate's HTTP upgrade: which requests may open a WebSocket, and the answers.
nonisolated enum GateHandshake {
  /// Why a request is refused, as an HTTP status (or, once open, a WebSocket close code).
  struct Refusal: Error, Equatable {
    let code: UInt16
    let reason: String

    static let forbidden = Self(code: 403, reason: "Forbidden")
  }

  /// An accepted upgrade: the scope its secret opens and its WebSocket key.
  struct Accepted: Equatable {
    let scope: String
    let key: String
  }

  /// Checks an upgrade request's head (without the blank line).
  /// - Parameters:
  ///   - head: The request line and headers.
  ///   - scopeForPath: The scope a path's secret opens, or `nil`.
  /// - Returns: The accepted upgrade, or the refusal to send.
  static func check(_ head: Data, scopeForPath: (String) -> String?) -> Result<Accepted, Refusal> {
    guard let text = String(bytes: head, encoding: .utf8) else {
      return .failure(Refusal(code: 400, reason: "Bad Request"))
    }
    let lines = text.components(separatedBy: "\r\n")
    let requestLine = lines.first?.split(separator: " ") ?? []
    guard requestLine.count == 3, requestLine[0] == "GET" else {
      return .failure(Refusal(code: 405, reason: "Method Not Allowed"))
    }
    let headers = Self.headers(lines.dropFirst())
    // A web page can open WebSockets to loopback; browsers always send its origin.
    guard headers["origin"] == nil else { return .failure(.forbidden) }
    let host = headers["host"]?.split(separator: ":").first.map(String.init) ?? ""
    guard host == "127.0.0.1" || host == "localhost" else { return .failure(.forbidden) }
    guard let scope = scopeForPath(String(requestLine[1])) else { return .failure(.forbidden) }
    guard headers["upgrade"]?.lowercased() == "websocket",
      headers["sec-websocket-version"] == "13", let key = headers["sec-websocket-key"],
      !key.isEmpty
    else { return .failure(Refusal(code: 400, reason: "Bad Request")) }
    return .success(Accepted(scope: scope, key: key))
  }

  /// The 101 answer for `key`.
  static func switchingProtocols(key: String) -> String {
    let accept = Data(
      Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
    ).base64EncodedString()
    return "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
      + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
  }

  /// The answer that refuses a request.
  static func refusal(_ refusal: Refusal) -> String {
    "HTTP/1.1 \(refusal.code) \(refusal.reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  }

  private static func headers(_ lines: ArraySlice<String>) -> [String: String] {
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    return headers
  }
}

/// One RFC 6455 frame: parsing a client's (masked) frames and encoding the server's.
nonisolated struct WebSocketFrame: Equatable {
  static let continuation: UInt8 = 0x0
  static let text: UInt8 = 0x1
  static let binary: UInt8 = 0x2
  static let close: UInt8 = 0x8
  static let ping: UInt8 = 0x9
  static let pong: UInt8 = 0xA

  let final: Bool
  let opcode: UInt8
  let payload: Data

  /// Takes one complete client frame off the front of `buffer`.
  /// - Returns: The frame, a close code for a malformed one, or `nil` while it is incomplete.
  static func take(from buffer: inout Data) -> Result<Self, GateHandshake.Refusal>? {
    let bytes = [UInt8](buffer.prefix(14))
    guard bytes.count >= 2 else { return nil }
    guard bytes[1] & 0x80 != 0 else {
      return .failure(GateHandshake.Refusal(code: 1002, reason: "Client frames must be masked"))
    }
    guard let encodedLength = payloadLength(bytes) else { return nil }
    let (length, lengthBytes) = encodedLength
    guard length <= UInt64(DevToolsGate.maximumMessageBytes) else {
      return .failure(GateHandshake.Refusal(code: 1009, reason: "Message too big"))
    }
    let maskOffset = 2 + lengthBytes
    guard bytes.count >= maskOffset + 4 else { return nil }
    let mask = Array(bytes[maskOffset..<maskOffset + 4])
    let start = buffer.startIndex + maskOffset + 4
    guard buffer.endIndex - start >= Int(length) else { return nil }
    let end = start + Int(length)
    var payload = [UInt8](buffer[start..<end])
    for index in payload.indices { payload[index] ^= mask[index % 4] }
    buffer = Data(buffer[end...])
    return .success(
      Self(final: bytes[0] & 0x80 != 0, opcode: bytes[0] & 0x0F, payload: Data(payload)))
  }

  /// The payload length and how many extra bytes encoded it; `nil` while they have not arrived.
  private static func payloadLength(_ bytes: [UInt8]) -> (UInt64, Int)? {
    let short = UInt64(bytes[1] & 0x7F)
    switch short {
    case 126:
      guard bytes.count >= 4 else { return nil }
      return (UInt64(bytes[2]) << 8 | UInt64(bytes[3]), 2)
    case 127:
      guard bytes.count >= 10 else { return nil }
      return (bytes[2..<10].reduce(0) { $0 << 8 | UInt64($1) }, 8)
    default:
      return (short, 0)
    }
  }

  /// One unmasked, final server frame.
  static func encode(opcode: UInt8, _ payload: Data) -> Data {
    var frame = Data([0x80 | opcode])
    switch payload.count {
    case 0..<126:
      frame.append(UInt8(payload.count))
    case 126..<65_536:
      frame.append(126)
      frame.append(UInt8(payload.count >> 8))
      frame.append(UInt8(payload.count & 0xFF))
    default:
      frame.append(127)
      for shift in stride(from: 56, through: 0, by: -8) {
        frame.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF))
      }
    }
    frame.append(payload)
    return frame
  }
}
