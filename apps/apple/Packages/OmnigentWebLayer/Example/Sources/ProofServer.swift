internal import Foundation
internal import Network

/// A loopback HTTP server for the proofs. 127.0.0.1 is a secure context, so permission APIs
/// work on its pages.
/// - `GET /set?v=<value>` answers with `Set-Cookie: owl=<value>`; `GET /read` echoes the Cookie.
/// - `GET /page/<name>` serves `Proofs.servedPages[name]`.
/// - `GET /download` is a 256 KiB `Content-Disposition: attachment` text file.
/// - `GET /auth` needs Basic `owl:secret` and answers 401 otherwise.
/// - `GET /redirect?to=<url>` answers 302 to `url`.
/// - `GET /icon.png` is a small PNG, for favicons.
/// - `/probe` answers like Okta Verify's FastPass loopback listener, with CORS and Private Network
///   Access headers, for any method (preflights included).
final class ProofServer {
  private let listener: NWListener
  private(set) var port: UInt16 = 0
  let pages: [String: String]

  nonisolated static let downloadSize = 256 * 1024
  nonisolated static let credential = "owl:secret"
  /// A 1x1 red PNG.
  nonisolated static let iconPNG =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

  /// - Parameters:
  ///   - pages: Pages served under `/page/`.
  ///   - fixedPort: A fixed port (the restore proof reuses one across a relaunch); any when nil.
  /// - Throws: When the listener cannot be created.
  init(pages: [String: String] = [:], port fixedPort: UInt16? = nil) throws {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
      host: "127.0.0.1", port: fixedPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
    listener = try NWListener(using: parameters)
    self.pages = pages
  }

  var base: String { "http://127.0.0.1:\(port)" }

  /// Starts listening and returns once the port is known.
  func start() async throws {
    let pages = pages
    listener.newConnectionHandler = { connection in
      connection.start(queue: .global())
      Self.serve(connection, pages: pages)
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

  private nonisolated static func serve(_ connection: NWConnection, pages: [String: String]) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
      if let error {
        FileHandle.standardError.write(Data("ProofServer receive failed: \(error)\n".utf8))
        connection.cancel()
        return
      }
      let request = String(bytes: data ?? Data(), encoding: .utf8) ?? ""
      connection.send(
        content: respond(to: request, pages: pages),
        completion: .contentProcessed { sendError in
          if let sendError {
            FileHandle.standardError.write(Data("ProofServer send failed: \(sendError)\n".utf8))
          }
          connection.cancel()
        })
    }
  }

  private nonisolated static func header(_ lines: [String], _ name: String) -> String? {
    lines.first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
      .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
  }

  /// Okta Verify's loopback answer: CORS for the asking origin and Private Network Access.
  private nonisolated static func probeResponse(origin: String) -> ([String], Data) {
    let headers = [
      "Content-Type: application/json", "Connection: close",
      "Access-Control-Allow-Origin: \(origin)", "Access-Control-Allow-Headers: *",
      "Access-Control-Allow-Private-Network: true", "Access-Control-Allow-Local-Network: true",
    ]
    return (headers, Data("{\"probe\":\"owl-mock-okta-verify\"}".utf8))
  }

  private nonisolated static func respond(to request: String, pages: [String: String]) -> Data {
    let lines = request.components(separatedBy: "\r\n")
    let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
    let query = URLComponents(string: target)?.queryItems ?? []
    let path = URLComponents(string: target)?.path ?? target
    var status = "200 OK"
    var headers = ["Content-Type: text/html; charset=utf-8", "Connection: close"]
    var body = Data()
    switch path {
    case "/set":
      let value = query.first { $0.name == "v" }?.value ?? "default"
      headers.append("Set-Cookie: owl=\(value); Path=/")
      body = Data("<title>set</title><p id=result>set owl=\(value)</p>".utf8)
    case "/read":
      let cookie = header(lines, "cookie") ?? "(none)"
      body = Data("<title>read</title><p id=result>cookie: \(cookie)</p>".utf8)
    case "/download":
      headers = [
        "Content-Type: application/octet-stream", "Connection: close",
        "Content-Disposition: attachment; filename=\"owl2-proof-download.txt\"",
      ]
      body = Data(repeating: UInt8(ascii: "o"), count: downloadSize)
    case "/auth":
      let expected = "Basic " + Data(credential.utf8).base64EncodedString()
      if header(lines, "authorization") == expected {
        body = Data("<title>authorized</title><p id=result>authorized as owl</p>".utf8)
      } else {
        status = "401 Unauthorized"
        headers.append("WWW-Authenticate: Basic realm=\"OWL Proof\"")
        body = Data("<title>unauthorized</title><p id=result>unauthorized</p>".utf8)
      }
    case "/icon.png":
      headers = ["Content-Type: image/png", "Connection: close"]
      body = Data(base64Encoded: iconPNG) ?? Data()
    case "/probe":
      (headers, body) = probeResponse(origin: header(lines, "origin") ?? "*")
    case "/redirect":
      status = "302 Found"
      headers.append("Location: \(query.first { $0.name == "to" }?.value ?? "/")")
    default:
      if path.hasPrefix("/page/"), let page = pages[String(path.dropFirst("/page/".count))] {
        body = Data(page.utf8)
      } else {
        status = "404 Not Found"
        body = Data("<title>missing</title>".utf8)
      }
    }
    headers.append("Content-Length: \(body.count)")
    let head = "HTTP/1.1 \(status)\r\n" + headers.joined(separator: "\r\n") + "\r\n\r\n"
    return Data(head.utf8) + body
  }
}

/// A threaded HTTPS server (Python's http.server over TLS) with a fresh self-signed certificate,
/// for the certificate-error proof. Threaded, because engines open parallel connections while a
/// certificate decision is pending.
final class SelfSignedTLSServer {
  private let process = Process()
  let port: UInt16

  init(directory: URL) throws {
    port = UInt16.random(in: 20_000...40_000)
    let key = directory.appending(path: "owl2-key.pem").path
    let cert = directory.appending(path: "owl2-cert.pem").path
    try Self.run(
      "/usr/bin/openssl",
      [
        "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "1",
        "-subj", "/CN=owl2-proof.invalid",
      ])
    let script = """
      import http.server, ssl, sys
      class Page(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              body = b"<title>OWL TLS</title><p id=result>self-signed page loaded</p>"
              self.send_response(200)
              self.send_header("Content-Type", "text/html")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)
          def log_message(self, *args):
              pass
      server = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Page)
      context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
      context.load_cert_chain(sys.argv[2], sys.argv[3])
      server.socket = context.wrap_socket(server.socket, server_side=True)
      server.serve_forever()
      """
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", script, "\(port)", cert, key]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
  }

  var url: URL? { URL(string: "https://127.0.0.1:\(port)/") }

  func stop() {
    process.terminate()
  }

  private static func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw ProofFailure(
        "\(tool) \(arguments.first ?? "") failed with \(process.terminationStatus)")
    }
  }
}
