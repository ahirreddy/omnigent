internal import Foundation
internal import Network

/// A loopback HTTP server for the cookie-isolation proof.
/// - `GET /set?v=<value>` answers with `Set-Cookie: owl=<value>`.
/// - `GET /read` echoes the request's Cookie header.
final class CookieServer {
  private let listener: NWListener
  private(set) var port: UInt16 = 0

  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
  }

  /// Starts listening and returns once the port is known.
  func start() async throws {
    listener.newConnectionHandler = { connection in
      connection.start(queue: .global())
      Self.serve(connection)
    }
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      listener.stateUpdateHandler = { [listener] state in
        switch state {
        case .ready:
          listener.stateUpdateHandler = nil
          continuation.resume(returning: listener.port?.rawValue ?? 0)
        case .failed(let error):
          listener.stateUpdateHandler = nil
          continuation.resume(throwing: error)
        default:
          break
        }
      }
      listener.start(queue: .global())
    }
    self.port = port
  }

  func stop() {
    listener.cancel()
  }

  private nonisolated static func serve(_ connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
      if let error {
        FileHandle.standardError.write(Data("CookieServer receive failed: \(error)\n".utf8))
        connection.cancel()
        return
      }
      let request = String(bytes: data ?? Data(), encoding: .utf8) ?? ""
      let response = respond(to: request)
      connection.send(
        content: Data(response.utf8),
        completion: .contentProcessed { sendError in
          if let sendError {
            FileHandle.standardError.write(Data("CookieServer send failed: \(sendError)\n".utf8))
          }
          connection.cancel()
        })
    }
  }

  private nonisolated static func respond(to request: String) -> String {
    let lines = request.components(separatedBy: "\r\n")
    let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
    let cookie =
      lines.first { $0.lowercased().hasPrefix("cookie:") }
      .map { String($0.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespaces) }
      ?? "(none)"
    var headers = ["Content-Type: text/html; charset=utf-8", "Connection: close"]
    let body: String
    if target.hasPrefix("/set") {
      let value =
        URLComponents(string: target)?.queryItems?.first { $0.name == "v" }?.value ?? "default"
      headers.append("Set-Cookie: owl=\(value); Path=/")
      body = "<title>set</title><p id=result>set owl=\(value)</p>"
    } else {
      body = "<title>read</title><p id=result>cookie: \(cookie)</p>"
    }
    headers.append("Content-Length: \(body.utf8.count)")
    return "HTTP/1.1 200 OK\r\n" + headers.joined(separator: "\r\n") + "\r\n\r\n" + body
  }
}
