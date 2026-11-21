import Darwin
import Foundation
import Synchronization
import Testing

@testable import OmnigentWebLayer

/// The loopback gate in front of Chromium's DevTools pipe: it listens only on request, opens
/// only for a scope's secret, and refuses web pages and other hosts.
@Suite("Agent DevTools gate")
struct AgentDevToolsGateTests {
  /// Messages the multiplexer would write to Chromium's pipe.
  nonisolated final class Upstream: Sendable {
    let sent = Mutex<[[String: String]]>([])

    func record(_ data: Data) {
      guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        Issue.record("The multiplexer wrote a message that is not a JSON object.")
        return
      }
      let flat = object.mapValues { String(describing: $0) }
      sent.withLock { $0.append(flat) }
    }
  }

  /// A gate over a multiplexer whose pipe is `upstream`.
  struct Fixture {
    let gate: DevToolsGate
    let multiplexer: DevToolsMultiplexer
    let upstream: Upstream
  }

  private func fixture(idle: Duration = .seconds(60)) -> Fixture {
    let upstream = Upstream()
    let multiplexer = DevToolsMultiplexer { upstream.record($0) }
    return Fixture(
      gate: DevToolsGate(multiplexer: multiplexer, idleTimeout: idle), multiplexer: multiplexer,
      upstream: upstream)
  }

  @Test("nothing listens until an agent's endpoint is asked for")
  func noListenerUntilAsked() async throws {
    let gate = fixture().gate
    #expect(!gate.isListening)
    let endpoint = try await gate.endpoint(scope: "conv_a")
    #expect(gate.isListening)
    #expect(endpoint.port > 0)
    #expect(endpoint.path.hasPrefix("/devtools/browser/"))
    gate.close()
    #expect(!gate.isListening)
    #expect(await eventually { (try? RawSocket(port: endpoint.port)) == nil })
  }

  @Test("each scope has its own secret, kept while the gate is open and dropped when it closes")
  func secretsArePerScope() async throws {
    let gate = fixture().gate
    defer { gate.close() }
    let first = try await gate.endpoint(scope: "conv_a")
    let again = try await gate.endpoint(scope: "conv_a")
    let other = try await gate.endpoint(scope: "conv_b")
    #expect(first == again)
    #expect(first.path != other.path)
    #expect(gate.scope(forPath: first.path) == "conv_a")
    #expect(gate.scope(forPath: other.path) == "conv_b")
    gate.close()
    let reopened = try await gate.endpoint(scope: "conv_a")
    #expect(reopened.path != first.path)
    #expect(gate.scope(forPath: first.path) == nil)
  }

  @Test("an endpoint never prints its secret")
  func endpointsDoNotPrintTheirSecret() async throws {
    let gate = fixture().gate
    defer { gate.close() }
    let endpoint = try await gate.endpoint(scope: "conv_a")
    let secret = String(endpoint.path.dropFirst(DevToolsGate.pathPrefix.count))
    #expect(secret.count == 64)
    #expect(!"\(endpoint)".contains(secret))
    #expect(!String(reflecting: endpoint).contains(secret))
  }

  @Test("requests without the secret, from a web page or for another host are refused")
  func refusals() async throws {
    let parts = fixture()
    let (gate, upstream) = (parts.gate, parts.upstream)
    defer { gate.close() }
    let endpoint = try await gate.endpoint(scope: "conv_a")
    let port = endpoint.port
    let wrongSecret = DevToolsGate.pathPrefix + String(repeating: "0", count: 64)
    let cases: [(path: String, headers: [String])] = [
      (wrongSecret, []),
      ("/json/version", []),
      (endpoint.path, ["Origin: https://example.com"]),
    ]
    for (path, headers) in cases {
      let socket = try RawSocket(port: port)
      let status = try socket.upgrade(path: path, port: port, extraHeaders: headers)
      #expect(status.hasPrefix("HTTP/1.1 403"), "\(path) \(headers)")
    }
    let socket = try RawSocket(port: port)
    let status = try socket.upgrade(path: endpoint.path, port: port, host: "evil.example")
    #expect(status.hasPrefix("HTTP/1.1 403"))
    #expect(upstream.sent.withLock { $0.isEmpty })
    #expect(gate.connectionCount <= 1)
  }

  @Test("an accepted connection reaches the pipe with its own ids")
  func acceptedConnectionsAreMultiplexed() async throws {
    let parts = fixture()
    let (gate, upstream) = (parts.gate, parts.upstream)
    let multiplexer = parts.multiplexer
    defer { gate.close() }
    let endpoint = try await gate.endpoint(scope: "conv_a")
    let socket = try RawSocket(port: endpoint.port)
    let status = try socket.upgrade(path: endpoint.path, port: endpoint.port)
    #expect(status.hasPrefix("HTTP/1.1 101"))
    try socket.sendText(#"{"id":7,"method":"Browser.getVersion"}"#)
    #expect(await eventually { upstream.sent.withLock { $0.count } == 1 })
    let forwarded = upstream.sent.withLock { $0[0] }
    #expect(forwarded["method"] == "Browser.getVersion")
    let upstreamID = try #require(forwarded["id"].flatMap(Int.init))
    multiplexer.upstreamMessage(Data(#"{"id":\#(upstreamID),"result":{"product":"Chrome"}}"#.utf8))
    let reply = try socket.readText()
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    #expect(object["id"] as? Int == 7)
    #expect(gate.connectionCount == 1)
  }

  @Test("the gate closes once nobody has used it for its idle time")
  func idleClose() async throws {
    let gate = fixture(idle: .milliseconds(200)).gate
    _ = try await gate.endpoint(scope: "conv_a")
    #expect(gate.isListening)
    #expect(await eventually { !gate.isListening })
  }

  private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<400 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }
}

/// A blocking loopback TCP client that speaks just enough WebSocket for the gate tests.
final class RawSocket {
  private let descriptor: Int32

  init(port: Int) throws {
    descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = unsafe setsockopt(
      descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    let connected = withUnsafePointer(to: &address) { pointer in
      unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
        unsafe connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else {
      close(descriptor)
      throw POSIXError(.ECONNREFUSED)
    }
  }

  deinit { close(descriptor) }

  /// Sends an upgrade request and returns the response's status line.
  func upgrade(
    path: String, port: Int, host: String = "127.0.0.1", extraHeaders: [String] = []
  ) throws -> String {
    let lines =
      [
        "GET \(path) HTTP/1.1", "Host: \(host):\(port)", "Upgrade: websocket",
        "Connection: Upgrade", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
      ] + extraHeaders
    try write(Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8))
    var head: [UInt8] = []
    while !head.suffix(4).elementsEqual([13, 10, 13, 10]) {
      head += try read(1)
    }
    return (String(bytes: head, encoding: .utf8) ?? "").components(separatedBy: "\r\n")[0]
  }

  /// Sends one masked text frame.
  func sendText(_ text: String) throws {
    let payload = [UInt8](text.utf8)
    let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
    var frame: [UInt8] = [0x81]
    if payload.count < 126 {
      frame.append(0x80 | UInt8(payload.count))
    } else {
      frame += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
    }
    frame += mask
    frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
    try write(Data(frame))
  }

  /// Reads one unmasked text frame.
  func readText() throws -> String {
    let header = try read(2)
    var length = Int(header[1] & 0x7F)
    if length == 126 {
      let extended = try read(2)
      length = Int(extended[0]) << 8 | Int(extended[1])
    } else if length == 127 {
      length = try read(8).reduce(0) { $0 << 8 | Int($1) }
    }
    return String(bytes: try read(length), encoding: .utf8) ?? ""
  }

  private func write(_ data: Data) throws {
    let written = unsafe data.withUnsafeBytes { bytes in
      unsafe Darwin.write(descriptor, bytes.baseAddress, bytes.count)
    }
    guard written == data.count else { throw POSIXError(.EPIPE) }
  }

  private func read(_ count: Int) throws -> [UInt8] {
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: max(count, 1))
    while bytes.count < count {
      let got = buffer.withUnsafeMutableBytes { raw in
        unsafe Darwin.read(descriptor, raw.baseAddress, count - bytes.count)
      }
      guard got > 0 else { throw POSIXError(.ETIMEDOUT) }
      bytes += buffer[0..<got]
    }
    return bytes
  }
}
