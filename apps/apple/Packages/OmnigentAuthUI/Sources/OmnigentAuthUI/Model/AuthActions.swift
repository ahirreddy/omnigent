/// A username and password to submit. The password is never printed: `description`,
/// `debugDescription` and reflection redact it.
public nonisolated struct AccountCredentials: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  /// The username, trimmed.
  public let username: String
  /// The password, exactly as typed.
  public let password: String

  /// Creates credentials.
  /// - Parameters:
  ///   - username: The username; surrounding whitespace is removed.
  ///   - password: The password, kept exactly.
  public init(username: String, password: String) {
    self.username = CredentialsInput.trimmedUsername(username)
    self.password = password
  }

  /// The username, with the password redacted.
  public var description: String {
    "AccountCredentials(username: \(username), password: <redacted>)"
  }

  /// The username, with the password redacted.
  public var debugDescription: String { description }

  /// The username only.
  public var customMirror: Mirror {
    Mirror(self, children: ["username": username, "password": "<redacted>"])
  }
}

/// What the sign-in UI asks the store to do. Every action is fire-and-forget: the store runs the
/// work and reports its progress and failures through ``AuthViewState/phase``.
public struct AuthActions {
  /// Connect to a server, as typed. The store normalizes it, discovers the server and connects.
  public var connect: @MainActor (String) -> Void
  /// Sign in with a username and password (accounts mode).
  public var submitCredentials: @MainActor (AccountCredentials) -> Void
  /// Start a browser sign-in with the given option.
  public var startBrowserSignIn: @MainActor (SignInOption) -> Void
  /// Stop the work in flight, or leave a sign-in form for the server picker, keeping the URL.
  public var cancel: @MainActor () -> Void
  /// Sign out of the connected account.
  public var signOut: @MainActor () -> Void
  /// Connect again to the last server.
  public var retry: @MainActor () -> Void
  /// Remove a server from the recents (organization servers cannot be forgotten).
  public var forgetServer: @MainActor (String) -> Void

  /// Creates actions.
  /// - Parameters:
  ///   - connect: Connect to a server, as typed.
  ///   - submitCredentials: Sign in with a username and password.
  ///   - startBrowserSignIn: Start a browser sign-in.
  ///   - cancel: Stop the work in flight or leave the form.
  ///   - signOut: Sign out of the connected account.
  ///   - retry: Connect again to the last server.
  ///   - forgetServer: Remove a server from the recents.
  public init(
    connect: @escaping @MainActor (String) -> Void,
    submitCredentials: @escaping @MainActor (AccountCredentials) -> Void,
    startBrowserSignIn: @escaping @MainActor (SignInOption) -> Void,
    cancel: @escaping @MainActor () -> Void,
    signOut: @escaping @MainActor () -> Void,
    retry: @escaping @MainActor () -> Void,
    forgetServer: @escaping @MainActor (String) -> Void
  ) {
    self.connect = connect
    self.submitCredentials = submitCredentials
    self.startBrowserSignIn = startBrowserSignIn
    self.cancel = cancel
    self.signOut = signOut
    self.retry = retry
    self.forgetServer = forgetServer
  }

  /// Actions that do nothing, for previews and snapshots only.
  public static let inert = Self(
    connect: { _ in }, submitCredentials: { _ in }, startBrowserSignIn: { _ in }, cancel: {},
    signOut: {}, retry: {}, forgetServer: { _ in })
}
