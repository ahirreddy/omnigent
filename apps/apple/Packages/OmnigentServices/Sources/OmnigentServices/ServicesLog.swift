import Foundation
import OSLog

/// Logger for failures that cannot be thrown to a caller, such as a non-throwing protocol method.
let servicesLogger = Logger(subsystem: "ai.omnigent", category: "services")

/// The log line for a request the server refused: method, URL without userinfo or query, status,
/// routing key (a host id), query parameter names, whether a workspace was named, and the start
/// of the server's answer. Never a query value, another header, a token or the request's body.
enum RefusedRequestLine {
  /// How much of the server's answer is kept.
  static let bodyLimit = 200

  /// The line for `request` answered with `status`, or `nil` below 400.
  /// - Parameters:
  ///   - request: The request that was sent.
  ///   - status: The response status.
  ///   - body: The response body, if read.
  /// - Returns: The line.
  static func make(_ request: URLRequest?, status: Int, body: Data?) -> String? {
    guard status >= 400 else { return nil }
    let method = request?.httpMethod ?? "GET"
    var components = request?.url.flatMap {
      URLComponents(url: $0, resolvingAgainstBaseURL: false)
    }
    let names = components?.queryItems?.map(\.name) ?? []
    components?.user = nil
    components?.password = nil
    components?.query = nil
    components?.fragment = nil
    let target = components?.string ?? "<no URL>"
    let key = request?.value(forHTTPHeaderField: "X-Databricks-Omnigent-Slice-Key") ?? "none"
    let workspace = request?.value(forHTTPHeaderField: "X-Databricks-Org-Id") == nil ? "no" : "yes"
    let query = names.isEmpty ? "none" : names.joined(separator: ",")
    var line = "HTTP \(status) \(method) \(target) key=\(key) query=\(query) org=\(workspace)"
    if let excerpt = excerpt(of: body) { line += " body=\(excerpt)" }
    return line
  }

  /// The first ``bodyLimit`` characters of `body` on one line; `nil` when there is none.
  static func excerpt(of body: Data?) -> String? {
    guard let body, !body.isEmpty else { return nil }
    // A cut inside a multi-byte character must not lose the text before it.
    // swiftlint:disable:next optional_data_string_conversion
    let text = String(decoding: body.prefix(bodyLimit * 4), as: UTF8.self)
    let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
    return flat.isEmpty ? nil : String(flat.prefix(bodyLimit))
  }
}

/// Logs a request the server refused (see ``RefusedRequestLine``).
/// - Parameters:
///   - request: The request that was sent.
///   - status: The response status.
///   - body: The response body, if read.
func logRefusedRequest(_ request: URLRequest?, status: Int, body: Data? = nil) {
  guard let line = RefusedRequestLine.make(request, status: status, body: body) else { return }
  servicesLogger.error("\(line, privacy: .public)")
}
