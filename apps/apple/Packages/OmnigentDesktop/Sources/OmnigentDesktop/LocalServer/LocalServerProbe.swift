public import Foundation

/// What `/.well-known/omnigent.json` advertised, or nothing for servers older than the route.
nonisolated public struct LocalServerManifest: Equatable, Sendable {
  /// The envelope version. Clients gate on `>=`.
  public var manifestVersion: Int
  /// The installed omnigent version, for display.
  public var serverVersion: String?
  /// The operator's display name, for display only.
  public var serverName: String?
  /// How the server signs users in (`none`, `accounts`, `oidc`, ...).
  public var authMode: String?

  /// Creates a manifest summary.
  /// - Parameters:
  ///   - manifestVersion: Envelope version.
  ///   - serverVersion: Server version.
  ///   - serverName: Display name.
  ///   - authMode: Sign-in mode.
  public init(
    manifestVersion: Int, serverVersion: String? = nil, serverName: String? = nil,
    authMode: String? = nil
  ) {
    self.manifestVersion = manifestVersion
    self.serverVersion = serverVersion
    self.serverName = serverName
    self.authMode = authMode
  }

  /// Decodes a manifest body, ignoring unknown fields.
  /// - Parameter data: The JSON body.
  /// - Returns: The summary.
  /// - Throws: A description of what is wrong.
  public static func decode(_ data: Data) throws(ProbeProblem) -> Self {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw ProbeProblem("the manifest is not JSON: \(error.localizedDescription)")
    }
    guard let fields = object as? [String: Any] else {
      throw ProbeProblem("the manifest is not a JSON object")
    }
    guard let version = fields["manifest_version"] as? Int, version >= 1 else {
      throw ProbeProblem("the manifest has no positive integer manifest_version")
    }
    let auth = fields["auth"] as? [String: Any]
    return Self(
      manifestVersion: version, serverVersion: fields["server_version"] as? String,
      serverName: fields["server_name"] as? String, authMode: auth?["mode"] as? String)
  }
}

/// A reason a probe did not succeed.
nonisolated public struct ProbeProblem: Error, Equatable, Sendable {
  /// The description.
  public var description: String

  /// Creates a problem.
  /// - Parameter description: The description.
  public init(_ description: String) {
    self.description = description
  }
}

/// The outcome of probing a loopback URL.
nonisolated public enum LocalServerProbeResult: Equatable, Sendable {
  /// `/health` answered `{"status":"ok"}` and the manifest was valid or absent (404).
  case ready(LocalServerManifest?)
  /// Nothing useful answered yet (connection refused, timeout, 5xx). Keep waiting.
  case notReady(String)
  /// Something answered that is not an Omnigent server. Do not use it.
  case rejected(String)
}

/// Probes a candidate server's `/health` and manifest.
nonisolated public protocol LocalServerProbing: Sendable {
  /// Probes `baseURL`.
  /// - Parameter baseURL: For example `http://127.0.0.1:6767`.
  /// - Returns: The outcome.
  func probe(_ baseURL: URL) async -> LocalServerProbeResult

  /// Whether the CLI's `bearer` is signed in to `serverURL`, before hosting for it.
  /// - Parameters:
  ///   - serverURL: The remote server.
  ///   - bearer: The CLI's stored token for it, if any.
  /// - Returns: The answer.
  func signInProbe(_ serverURL: URL, bearer: String?) async -> CLISignInProbe
}

/// Probes with an ephemeral `URLSession` that ignores system proxies and refuses redirects, so
/// a loopback probe can never be answered by anything but the local listener.
nonisolated public struct URLSessionLocalServerProbe: LocalServerProbing {
  private let session: URLSession

  /// Creates a probe.
  /// - Parameter timeout: Per-request timeout.
  public init(timeout: Duration = .seconds(2)) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = Double(timeout.components.seconds)
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    session = URLSession(configuration: configuration)
  }

  /// Probes `/health`, then `/.well-known/omnigent.json`.
  /// - Parameter baseURL: The server.
  /// - Returns: The outcome.
  public func probe(_ baseURL: URL) async -> LocalServerProbeResult {
    let health: (Data, Int)
    do {
      health = try await get(baseURL.appending(path: "health"))
    } catch {
      return .notReady(error.description)
    }
    guard health.1 == 200 else {
      return health.1 >= 500
        ? .notReady("/health returned HTTP \(health.1)")
        : .rejected("/health returned HTTP \(health.1)")
    }
    if let problem = Self.healthProblem(health.0) { return .rejected(problem) }
    let manifest: (Data, Int)
    do {
      manifest = try await get(baseURL.appending(path: ".well-known/omnigent.json"))
    } catch {
      return .notReady(error.description)
    }
    switch manifest.1 {
    case 200:
      do {
        return .ready(try LocalServerManifest.decode(manifest.0))
      } catch {
        return .rejected(error.description)
      }
    // Servers older than the manifest route are the pre-manifest baseline, not an error.
    case 404: return .ready(nil)
    case 500...: return .notReady("the manifest returned HTTP \(manifest.1)")
    default: return .rejected("the manifest returned HTTP \(manifest.1)")
    }
  }

  /// Why a 200 `/health` body is not Omnigent's `{"status": "ok"}`, or `nil` when it is.
  static func healthProblem(_ body: Data) -> String? {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: body)
    } catch {
      return "/health did not return JSON: \(error.localizedDescription)"
    }
    guard (object as? [String: Any])?["status"] as? String == "ok" else {
      return "/health did not answer {\"status\": \"ok\"}"
    }
    return nil
  }

  /// The status `request` answers with, redirects unfollowed.
  func statusCode(for request: URLRequest) async throws -> Int {
    let (_, response) = try await session.data(for: request, delegate: RefuseRedirects())
    guard let http = response as? HTTPURLResponse else {
      throw ProbeProblem("\(request.url?.path() ?? "") did not return an HTTP response")
    }
    return http.statusCode
  }

  private func get(_ url: URL) async throws(ProbeProblem) -> (Data, Int) {
    do {
      let (data, response) = try await session.data(
        for: URLRequest(url: url), delegate: RefuseRedirects())
      guard let http = response as? HTTPURLResponse else {
        throw ProbeProblem("\(url.path()) did not return an HTTP response")
      }
      return (data, http.statusCode)
    } catch let problem as ProbeProblem {
      throw problem
    } catch {
      throw ProbeProblem("\(url.path()): \(error.localizedDescription)")
    }
  }
}

/// Leaves 3xx responses unfollowed, so they surface as non-200 statuses.
nonisolated private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    // The completion-handler form: the async form crashes Swift 6.4's ObjC thunk emission.
    completionHandler(nil)
  }
}
