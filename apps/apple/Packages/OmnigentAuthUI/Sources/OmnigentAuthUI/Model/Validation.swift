import Foundation

/// Why a server URL was rejected, in the core's words.
public nonisolated struct ServerURLRejection: Error, Hashable, Sendable {
  /// For display, for example "This build requires https:// server URLs."
  public var message: String

  /// Creates a rejection.
  /// - Parameter message: For display.
  public init(message: String) {
    self.message = message
  }
}

/// The outcome of checking a typed server URL.
public nonisolated enum ServerURLCheck: Hashable, Sendable {
  /// Nothing typed yet; Connect is disabled and no message shows.
  case empty
  /// Accepted; `normalized` is what connecting will use.
  case valid(normalized: String)
  /// Rejected, with the reason to show under the field.
  case invalid(message: String)

  /// Whether Connect is enabled.
  public var canConnect: Bool {
    if case .valid = self { return true }
    return false
  }
}

/// Checks typed server URLs with the core's normalizer.
///
/// The rules (schemes, the release https policy, loopback, the Databricks `?o=` selector) live in
/// Rust. The app builds this from `omnigent-ffi` `normalize_server_url(server_url, policy)`; the
/// package only trims, handles the empty field and decides when to show the result.
public nonisolated struct ServerURLValidator: Sendable {
  /// The core's normalizer: the canonical URL, or why it is rejected.
  public var normalize: @Sendable (String) -> Result<String, ServerURLRejection>

  /// Creates a validator.
  /// - Parameter normalize: The core's normalizer.
  public init(normalize: @escaping @Sendable (String) -> Result<String, ServerURLRejection>) {
    self.normalize = normalize
  }

  /// Checks `raw`.
  /// - Parameter raw: The field's text.
  /// - Returns: The outcome.
  public func check(_ raw: String) -> ServerURLCheck {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .empty }
    switch normalize(trimmed) {
    case .success(let normalized): return .valid(normalized: normalized)
    case .failure(let rejection): return .invalid(message: rejection.message)
    }
  }

  /// The hint under the field: the rejection, or where a valid entry will connect when that
  /// differs from what was typed. `nil` hides the hint, which it does until the user submits or
  /// leaves a non-empty field, so a half-typed URL is not flagged.
  /// - Parameters:
  ///   - raw: The field's text.
  ///   - revealed: Whether the user has submitted or left the field.
  /// - Returns: The hint and whether it is an error.
  public func hint(for raw: String, revealed: Bool) -> (text: String, isError: Bool)? {
    switch check(raw) {
    case .empty:
      return nil
    case .invalid(let message):
      return revealed ? (message, true) : nil
    case .valid(let normalized):
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      return normalized == trimmed ? nil : ("Connects to \(normalized)", false)
    }
  }

  /// A stand-in for previews, snapshots and tests only. It approximates the release policy
  /// (https, or http to loopback; a schemeless entry gets https) and is not the app's rule.
  public static let preview = Self { raw in
    let loopback = ["localhost", "127.0.0.1", "[::1]"]
    let isLoopback = loopback.contains { raw.hasPrefix($0) || raw.hasPrefix("http://\($0)") }
    let withScheme =
      raw.contains("://") ? raw : (isLoopback ? "http://" : "https://") + raw
    guard let components = URLComponents(string: withScheme), let host = components.host,
      !host.isEmpty, !host.contains(" ")
    else {
      return .failure(ServerURLRejection(message: "Invalid URL: \(withScheme)"))
    }
    switch components.scheme {
    case "https":
      break
    case "http" where loopback.contains(host) || loopback.contains("[\(host)]"):
      break
    case "http":
      return .failure(ServerURLRejection(message: "This build requires https:// server URLs."))
    default:
      return .failure(
        ServerURLRejection(message: "Unsupported scheme '\(components.scheme ?? "")'. Use https."))
    }
    var display = withScheme
    while display.hasSuffix("/") { display.removeLast() }
    return .success(display)
  }
}

/// Presentational checks for the accounts form.
public nonisolated enum CredentialsInput {
  /// `username` without surrounding whitespace.
  /// - Parameter username: The field's text.
  /// - Returns: The trimmed username.
  public static func trimmedUsername(_ username: String) -> String {
    username.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Whether Sign In is enabled: a non-blank username, a non-empty password, and no sign-in
  /// already running. The password is not trimmed; spaces may be part of it.
  /// - Parameters:
  ///   - username: The username field.
  ///   - password: The password field.
  ///   - isSubmitting: Whether a sign-in is running.
  /// - Returns: Whether the form can be submitted.
  public static func canSubmit(username: String, password: String, isSubmitting: Bool) -> Bool {
    !isSubmitting && !trimmedUsername(username).isEmpty && !password.isEmpty
  }

  /// Where Return in a field goes next.
  public enum Step: Hashable, Sendable {
    /// Move focus to the password field.
    case focusPassword
    /// Move focus to the username field, which is still blank.
    case focusUsername
    /// Submit the form.
    case submit
    /// Stay: a sign-in is already running.
    case none
  }

  /// What Return does: submit once both fields are filled; otherwise a filled username moves to
  /// the password, and the password field returns to a blank username.
  /// - Parameters:
  ///   - fromPassword: Whether Return was pressed in the password field.
  ///   - username: The username field.
  ///   - password: The password field.
  ///   - isSubmitting: Whether a sign-in is running.
  /// - Returns: The next step.
  public static func returnStep(
    fromPassword: Bool, username: String, password: String, isSubmitting: Bool
  ) -> Step {
    if isSubmitting { return .none }
    if canSubmit(username: username, password: password, isSubmitting: false) { return .submit }
    let hasUsername = !trimmedUsername(username).isEmpty
    if !fromPassword { return hasUsername ? .focusPassword : .none }
    return hasUsername ? .none : .focusUsername
  }
}
