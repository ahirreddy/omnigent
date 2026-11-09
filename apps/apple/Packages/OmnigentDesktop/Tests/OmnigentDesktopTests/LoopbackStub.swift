import Foundation
import Network

/// A one-file HTTP server on loopback that answers each path from a table.
final class LoopbackStub: Sendable {
  struct Reply: Sendable {
    var status: Int
    var body = ""
    var headers: [String: String] = [:]
  }

  private let listener: NWListener
  let port: Int

  init(_ replies: [String: Reply]) async throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { connection in
      Self.serve(connection, replies: replies)
    }
    let ready = AsyncStream<Int>.makeStream()
    let listener = listener
    listener.stateUpdateHandler = { state in
      if case .ready = state {
        ready.continuation.yield(Int(listener.port?.rawValue ?? 0))
        ready.continuation.finish()
      }
    }
    listener.start(queue: DispatchQueue(label: "loopback-stub"))
    var bound = 0
    for await value in ready.stream { bound = value }
    port = bound
  }

  var url: URL {
    get throws { try OmnigentDesktopTests.url("http://127.0.0.1:\(port)") }
  }

  func stop() { listener.cancel() }

  private static func serve(_ connection: NWConnection, replies: [String: Reply]) {
    connection.start(queue: DispatchQueue(label: "loopback-stub-connection"))
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
      let request = data.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
      let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
      let reply = replies[path] ?? Reply(status: 404)
      let headers = reply.headers.map { "\($0.key): \($0.value)\r\n" }.joined()
      let head =
        "HTTP/1.1 \(reply.status) Status\r\nContent-Length: \(reply.body.utf8.count)\r\n"
        + "Connection: close\r\n\(headers)\r\n"
      connection.send(
        content: Data((head + reply.body).utf8),
        completion: .contentProcessed { _ in connection.cancel() })
    }
  }
}
