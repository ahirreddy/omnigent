import OSLog

/// Logger for failures that cannot be thrown to a caller, such as a non-throwing protocol method.
let servicesLogger = Logger(subsystem: "ai.omnigent", category: "services")

/// Logs a request the server refused: method, URL without userinfo, and status, so a failure the
/// UI shows as a bare status can be traced. Never headers; Debug builds add the start of the
/// body (the server's error text).
/// - Parameters:
///   - method: The HTTP method.
///   - url: The request URL.
///   - status: The response status.
///   - body: The response body, if read.
func logRefusedRequest(method: String, url: URL?, status: Int, body: Data? = nil) {
  guard status >= 400 else { return }
  var components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
  components?.user = nil
  components?.password = nil
  let target = components?.string ?? "<no URL>"
  #if DEBUG
    let excerpt =
      body.map { String(bytes: $0.prefix(300), encoding: .utf8) ?? "<\($0.count) bytes>" } ?? ""
    servicesLogger.error(
      "HTTP \(status, privacy: .public) \(method, privacy: .public) \(target, privacy: .public) \(excerpt, privacy: .public)"
    )
  #else
    servicesLogger.error(
      "HTTP \(status, privacy: .public) \(method, privacy: .public) \(target, privacy: .public)")
  #endif
}
