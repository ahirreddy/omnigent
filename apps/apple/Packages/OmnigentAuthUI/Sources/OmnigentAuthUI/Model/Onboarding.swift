public import Foundation

/// Where "Get started locally" stands on this Mac: the `omnigent` CLI and the local server.
///
/// The app builds it from its local server manager; platforms without one leave
/// ``AuthViewState/localSetup`` `nil`, and the flow offers only servers to join.
public nonisolated struct LocalSetupState: Hashable, Sendable {
  /// The `omnigent` CLI lookup.
  public enum CLI: Hashable, Sendable {
    /// Not looked for yet, or looking.
    case checking
    /// Found.
    case found
    /// Not found, with why.
    case missing(String)
  }

  /// The local server.
  public enum Server: Hashable, Sendable {
    /// Not running.
    case stopped
    /// Starting, restarting or stopping, with a short description.
    case busy(String)
    /// Ready at `url`.
    case running(url: String)
    /// Starting failed or it crashed, with why.
    case failed(String)
  }

  /// The CLI lookup.
  public var cli: CLI
  /// The local server.
  public var server: Server
  /// The server's most recent output lines, oldest first.
  public var log: [String]

  /// Creates a state.
  /// - Parameters:
  ///   - cli: The CLI lookup.
  ///   - server: The local server.
  ///   - log: Recent output lines.
  public init(cli: CLI, server: Server, log: [String] = []) {
    self.cli = cli
    self.server = server
    self.log = log
  }

  /// Whether the server already runs, so the action opens it rather than starting it.
  public var isRunning: Bool {
    if case .running = server { return true }
    return false
  }

  /// Whether the CLI is missing, so the action explains how to install it.
  public var needsCLI: Bool {
    if case .missing = cli { return !isRunning }
    return false
  }
}

/// What the local setup screens ask the app to do.
public struct LocalSetupActions {
  /// Start the local server (or reuse a running one), then connect this window to it.
  public var start: @MainActor () -> Void
  /// Look for the CLI again, after the user installed it.
  public var recheckCLI: @MainActor () -> Void
  /// Once signed in to the server, connect this Mac to it as a host.
  public var hostAfterSignIn: @MainActor (String) -> Void
  /// Show the local server's full log, when the app has a window for it.
  public var showLogs: (@MainActor () -> Void)?

  /// Creates actions.
  /// - Parameters:
  ///   - start: Start or reuse the local server, then connect to it.
  ///   - recheckCLI: Look for the CLI again.
  ///   - hostAfterSignIn: Host for a server once signed in to it.
  ///   - showLogs: Show the server's full log.
  public init(
    start: @escaping @MainActor () -> Void, recheckCLI: @escaping @MainActor () -> Void,
    hostAfterSignIn: @escaping @MainActor (String) -> Void,
    showLogs: (@MainActor () -> Void)? = nil
  ) {
    self.start = start
    self.recheckCLI = recheckCLI
    self.hostAfterSignIn = hostAfterSignIn
    self.showLogs = showLogs
  }

  /// Where to read how to install the CLI.
  public static let installGuideURL = URL(
    string: "https://omnigent.ai/quickstart/install#install-omnigent")

  /// Actions that do nothing, for previews and snapshots only.
  public static let inert = Self(start: {}, recheckCLI: {}, hostAfterSignIn: { _ in })
}

/// A step of the first-run flow shown while no server is chosen.
public nonisolated enum OnboardingStep: Hashable, Sendable {
  /// "Meet Omnigent": get started locally, or join your team.
  case landing
  /// What the local setup gives you, with Start (or Open) Omnigent.
  case localIntro
  /// Starting the local server, with its output.
  case localProgress
  /// How to install the CLI, with Check Again.
  case installCLI
  /// The server list: organization servers, recents and a URL field.
  case servers
  /// "Where do you work today?" before joining `serverUrl`.
  case runner(serverUrl: String)

  /// Where the flow opens. A failed connect, a returning user and a platform with nothing to
  /// set up locally open the server list; a new user sees the landing.
  /// - Parameters:
  ///   - directory: The servers on offer.
  ///   - banner: The picker's banner.
  ///   - offersLocalSetup: Whether this platform can run a local server.
  /// - Returns: The first step.
  public static func initial(
    directory: ServerDirectory, banner: AuthBanner?, offersLocalSetup: Bool
  ) -> Self {
    if case .error = banner { return .servers }
    if !directory.recentServers.isEmpty { return .servers }
    if !offersLocalSetup && directory.managed.isEmpty { return .servers }
    return .landing
  }

  /// Whether joining `serverUrl` first asks where agents run: a new user joining a remote
  /// server from a Mac that can host.
  /// - Parameters:
  ///   - serverUrl: The server to join.
  ///   - directory: The servers on offer.
  ///   - localSetup: This Mac's local setup, when it has one.
  /// - Returns: Whether to show ``runner(serverUrl:)``.
  public static func asksForRunner(
    joining serverUrl: String, directory: ServerDirectory, localSetup: LocalSetupState?
  ) -> Bool {
    guard localSetup != nil, directory.recentServers.isEmpty else { return false }
    return !LocalInstall.isLoopback(serverUrl)
  }
}

/// Whether a recent server answers, for the server list.
public nonisolated enum ServerReachability: Hashable, Sendable {
  /// An Omnigent server, with the name it gives itself.
  case omnigent(name: String?)
  /// Something answers, but not as an Omnigent server.
  case reachable
  /// Nothing answers.
  case unreachable
}

/// Loopback servers and the CLI's local install.
public nonisolated enum LocalInstall {
  /// The CLI's local server port (`omnigent/host/local_server.py`).
  public static let port = 6767

  /// Whether `url` is on this machine.
  /// - Parameter url: A server URL.
  /// - Returns: Whether its host is loopback.
  public static func isLoopback(_ url: String) -> Bool {
    guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
    return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
  }

  /// Whether `url` is the CLI's local install: a plain-HTTP loopback root on its port, which
  /// Start Omnigent boots. Any other loopback URL is an exact destination.
  /// - Parameter url: A server URL.
  /// - Returns: Whether it is the local install.
  public static func isLocalInstall(_ url: String) -> Bool {
    guard isLoopback(url), let components = URLComponents(string: url) else { return false }
    let path = components.path
    return components.scheme == "http" && components.port == port && (path.isEmpty || path == "/")
  }
}

/// Which account form the accounts screen shows.
public nonisolated enum AccountForm: Hashable, Sendable {
  /// Sign in with an existing account.
  case signIn
  /// Create the server's first administrator.
  case createAdmin
  /// Create an account with an invite.
  case register
}

/// An account to create, with its credentials. Like ``AccountCredentials``, the password is
/// never printed.
public nonisolated struct AccountCreationRequest: Sendable {
  /// The server's first administrator, or an invited user with the invite token.
  public enum Kind: Hashable, Sendable {
    /// The first administrator.
    case firstAdmin
    /// An invited user.
    case invited(token: String)
  }

  /// What to create.
  public var kind: Kind
  /// The username and password.
  public var credentials: AccountCredentials

  /// Creates a request.
  /// - Parameters:
  ///   - kind: What to create.
  ///   - credentials: The username and password.
  public init(kind: Kind, credentials: AccountCredentials) {
    self.kind = kind
    self.credentials = credentials
  }
}

/// Checks for the account creation form, as the web's Setup and Register pages check.
public nonisolated enum AccountFormInput {
  /// The server's minimum password length.
  public static let minimumPasswordLength = 8

  /// Usernames are lowercase on the server; the form lowercases as the user types.
  /// - Parameter username: The field's text.
  /// - Returns: The username to send.
  public static func normalizedUsername(_ username: String) -> String {
    CredentialsInput.trimmedUsername(username).lowercased()
  }

  /// Why the form cannot be submitted yet, or `nil` when it can. Blank fields return `nil`
  /// with ``canSubmit(username:password:confirmation:requiresInvite:invite:)`` false, so nothing is flagged
  /// before the user types.
  /// - Parameters:
  ///   - password: The password.
  ///   - confirmation: The repeated password.
  /// - Returns: The problem to show.
  public static func problem(password: String, confirmation: String) -> String? {
    if password.isEmpty || confirmation.isEmpty { return nil }
    if password.count < minimumPasswordLength {
      return "Password must be at least \(minimumPasswordLength) characters."
    }
    if password != confirmation { return "Passwords don\u{2019}t match." }
    return nil
  }

  /// Whether Create Account is enabled.
  /// - Parameters:
  ///   - username: The username.
  ///   - password: The password.
  ///   - confirmation: The repeated password.
  ///   - requiresInvite: Whether this is an invited account.
  ///   - invite: The invite token read from the invite field.
  /// - Returns: Whether the form can be submitted.
  public static func canSubmit(
    username: String, password: String, confirmation: String, requiresInvite: Bool,
    invite: String?
  ) -> Bool {
    if requiresInvite && invite == nil { return false }
    return !normalizedUsername(username).isEmpty && !password.isEmpty
      && password == confirmation && password.count >= minimumPasswordLength
  }
}
