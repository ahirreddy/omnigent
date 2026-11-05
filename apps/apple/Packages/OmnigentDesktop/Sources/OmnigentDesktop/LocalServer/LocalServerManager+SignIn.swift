public import Foundation

/// Whether the CLI is signed in to a server, as `GET /v1/me` with its stored token answers.
nonisolated public enum CLISignInProbe: Equatable, Sendable {
  /// `200`: signed in.
  case signedIn
  /// Anything else (a `401`, a redirect to a sign-in page): `omnigent login` is needed.
  case signInNeeded
  /// Nothing answered; the host's own connect reports the clearer error.
  case unreachable
}

/// The CLI's stored session tokens (`~/.omnigent/auth_tokens.json`, always under the home
/// directory), keyed by server URL. A Databricks pointer record has no token to send.
nonisolated enum CLIAuthTokens {
  /// The unexpired token for `serverURL`.
  /// - Parameters:
  ///   - serverURL: The server.
  ///   - home: The home directory.
  ///   - now: The current time.
  /// - Returns: The token, or `nil` when there is none, it expired, or the file is unreadable
  ///   (the probe then asks the server, which answers sign-in needed).
  static func bearer(for serverURL: URL, home: URL, now: Date = Date()) -> String? {
    let file = home.appending(path: ".omnigent/auth_tokens.json")
    guard let data = try? Data(contentsOf: file),  // Missing or unreadable: no token to offer.
      let records = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    var key = serverURL.absoluteString
    while key.hasSuffix("/") { key.removeLast() }
    guard let entry = records[key] as? [String: Any], let token = entry["token"] as? String,
      !token.isEmpty
    else { return nil }
    if let expiry = entry["expires_at"] as? Double, expiry < now.timeIntervalSince1970 {
      return nil
    }
    return token
  }
}

/// Signing the CLI in to a remote server before this Mac hosts for it, as the Electron shell's
/// `ensureServerAuth` does: `omnigent host --non-interactive` cannot open a browser itself.
extension LocalServerManager {
  /// How long `omnigent login` may wait for the user to finish in the browser; the CLI's own
  /// ticket deadline is 300 seconds.
  static let loginTimeout: Duration = .seconds(305)

  /// Signs the CLI in to `target` when it is remote and not signed in. A loopback server needs
  /// no sign-in, and an unreachable one is left to the host's connect to report.
  /// - Parameter target: The server to host for.
  /// - Returns: Success, or `.hostAuthenticationRequired` when the sign-in did not complete.
  func signInCLI(to target: URL) async -> Result<Void, LocalServerError> {
    guard !Self.isLoopback(target) else { return .success(()) }
    let bearer = CLIAuthTokens.bearer(for: target, home: dependencies.homeDirectory)
    switch await dependencies.probe.signInProbe(target, bearer: bearer) {
    case .signedIn, .unreachable: return .success(())
    case .signInNeeded: break
    }
    guard let resolution = await resolveCLI() else { return .failure(cliError) }
    hostLog.appendEvent(
      "Signing in to \(target.absoluteString). If a browser window opens, finish signing in there.")
    let launch = LocalProcessLaunch(
      executable: resolution.command.executable,
      arguments: resolution.command.arguments(["login", target.absoluteString]),
      environment: childEnvironment(resolution), workingDirectory: dependencies.homeDirectory)
    // The output is not logged: on OIDC servers it carries the login ticket URL.
    let failed = LocalServerError.hostAuthenticationRequired(
      serverURL: target, detail: "omnigent login did not complete")
    do {
      let result = try await LocalCommand.run(
        launch, runner: dependencies.runner, clock: dependencies.clock,
        timeout: Self.loginTimeout)
      guard result.exit.isSuccess else { return .failure(failed) }
      hostLog.appendEvent("Signed in. Connecting this Mac to the server\u{2026}")
      return .success(())
    } catch {
      hostLog.appendEvent(error.message)
      return .failure(failed)
    }
  }

  private static func isLoopback(_ url: URL) -> Bool {
    let host = url.host(percentEncoded: false)?.lowercased() ?? ""
    return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
  }
}

extension URLSessionLocalServerProbe {
  /// `GET <server>/v1/me` with `bearer`, never following a redirect, so a Databricks sign-in
  /// redirect reads as sign-in needed rather than as its `200` login page.
  public func signInProbe(_ serverURL: URL, bearer: String?) async -> CLISignInProbe {
    var request = URLRequest(url: serverURL.appending(path: "v1/me"), timeoutInterval: 10)
    if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    do {
      let status = try await statusCode(for: request)
      return status == 200 ? .signedIn : .signInNeeded
    } catch {
      return .unreachable
    }
  }
}
