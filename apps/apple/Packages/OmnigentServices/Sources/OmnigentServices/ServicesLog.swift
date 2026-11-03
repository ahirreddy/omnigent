import OSLog

/// Logger for failures that cannot be thrown to a caller, such as a non-throwing protocol method.
let servicesLogger = Logger(subsystem: "ai.omnigent", category: "services")

/// Logs a request the server refused: method, URL without userinfo, status, and the replica
/// routing key it carried (a host id), so a failure the UI shows as a bare status can be traced.
/// No other headers; Debug builds add the start of the body (the server's error text).
/// - Parameters:
///   - request: The request that was sent.
///   - status: The response status.
///   - body: The response body, if read.
func logRefusedRequest(_ request: URLRequest?, status: Int, body: Data? = nil) {
  let method = request?.httpMethod ?? "GET"
  let url = request?.url
  let key = request?.value(forHTTPHeaderField: "X-Databricks-Omnigent-Slice-Key") ?? "none"
  guard status >= 400 else { return }
  var components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
  components?.user = nil
  components?.password = nil
  let target = components?.string ?? "<no URL>"
  #if DEBUG
    let excerpt =
      body.map { String(bytes: $0.prefix(300), encoding: .utf8) ?? "<\($0.count) bytes>" } ?? ""
    servicesLogger.error(
      "HTTP \(status, privacy: .public) \(method, privacy: .public) \(target, privacy: .public) key=\(key, privacy: .public) \(excerpt, privacy: .public)"
    )
  #else
    servicesLogger.error(
      "HTTP \(status, privacy: .public) \(method, privacy: .public) \(target, privacy: .public) key=\(key, privacy: .public)"
    )
  #endif
}
