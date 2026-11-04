/// One named sample state, for previews, the gallery and snapshots.
public nonisolated struct AuthSample: Hashable, Sendable, Identifiable {
  /// A stable file-name-safe identifier, for example `password-error`.
  public let id: String
  /// What the sample shows.
  public let title: String
  /// The state.
  public let state: AuthViewState
}

/// Sample data for every sign-in state. The messages are the Rust core's own texts.
public nonisolated enum AuthSamples {
  /// An OIDC server's API root.
  public static let oidcUrl = "https://omnigent.example.com"
  /// An accounts server's API root.
  public static let accountsUrl = "https://agents.acme.dev/api/omnigent"
  /// A Databricks workspace's Omnigent mount.
  public static let workspaceUrl = "https://dbc-1234.cloud.databricks.com/omnigent?o=1234567890"

  /// The organization and recent servers.
  public static let directory = ServerDirectory(
    managed: [
      ManagedServerEntry(
        url: "https://omnigent.corp.example.com", name: "Acme Agents",
        origin: "https://omnigent.corp.example.com", authority: "omnigent.corp.example.com",
        displayName: "Acme Agents"),
      ManagedServerEntry(
        url: "https://staging.omnigent.corp.example.com", name: nil,
        origin: "https://staging.omnigent.corp.example.com",
        authority: "staging.omnigent.corp.example.com",
        displayName: "staging.omnigent.corp.example.com"),
    ],
    serversAreForced: false,
    recentServers: [oidcUrl, "http://127.0.0.1:6767", accountsUrl]
  )

  static let oidcServer = ServerIdentity(
    baseUrl: oidcUrl, serverName: "Example Agents", serverVersion: "0.9.2", mode: .oidc)
  static let accountsServer = ServerIdentity(
    baseUrl: accountsUrl, serverName: "Acme Agents", serverVersion: "0.9.1", mode: .accounts)
  static let workspaceServer = ServerIdentity(
    baseUrl: workspaceUrl, serverName: nil, serverVersion: "0.9.2", mode: .proxy)
  static let oidcMethods: [SignInOption] = [
    .loopbackBrowser(path: "/oauth/callback"), .browserTicket,
  ]

  /// Every sample, in flow order.
  public static let all: [AuthSample] = [
    AuthSample(
      id: "landing", title: "First-run landing",
      state: AuthViewState(localSetup: LocalSetupState(cli: .found, server: .stopped))),
    AuthSample(
      id: "landing-organization", title: "First-run landing with organization servers",
      state: AuthViewState(
        directory: ServerDirectory(managed: directory.managed),
        localSetup: LocalSetupState(cli: .found, server: .stopped))),
    AuthSample(
      id: "create-admin", title: "Create the first admin",
      state: AuthViewState(
        phase: .signInRequired(
          baseUrl: accountsUrl, serverName: "Acme Agents", mode: .accounts, methods: [.password],
          reason: nil),
        server: accountsServer, accountForm: .createAdmin)),
    AuthSample(
      id: "register", title: "Create an invited account",
      state: AuthViewState(
        phase: .signInRequired(
          baseUrl: accountsUrl, serverName: "Acme Agents", mode: .accounts, methods: [.password],
          reason: SignInError(
            category: .auth, failure: .refused(reason: "invite invalid or expired"),
            message: "The server did not create the account.")),
        server: accountsServer, accountForm: .register)),
    AuthSample(
      id: "picker", title: "Server picker",
      state: AuthViewState(directory: directory, lastServerUrl: "")),
    AuthSample(
      id: "picker-signed-out", title: "Server picker after sign-out",
      state: AuthViewState(
        directory: directory, lastServerUrl: oidcUrl,
        notice: "You\u{2019}re signed out of omnigent.example.com.")),
    AuthSample(
      id: "picker-unreachable", title: "Connection error (Jamf hint)",
      state: AuthViewState(
        phase: .failed(
          serverUrl: "https://omnigent.corp.example.com",
          error: SignInError(
            category: .transport,
            message:
              "Couldn\u{2019}t reach the server. Check your device\u{2019}s compliance status in Jamf."
          )),
        directory: directory)),
    AuthSample(
      id: "picker-invalid-url", title: "Rejected URL",
      state: AuthViewState(
        phase: .failed(
          serverUrl: "http://omnigent.example.com",
          error: SignInError(
            category: .invalidUrl, message: "This build requires https:// server URLs.")),
        directory: ServerDirectory())),
    AuthSample(
      id: "discovering", title: "Discovering",
      state: AuthViewState(phase: .discovering(serverUrl: oidcUrl), directory: directory)),
    AuthSample(
      id: "password", title: "Accounts sign-in",
      state: AuthViewState(
        phase: .signInRequired(
          baseUrl: accountsUrl, serverName: "Acme Agents", mode: .accounts, methods: [.password],
          reason: nil),
        server: accountsServer)),
    AuthSample(
      id: "password-error", title: "Accounts sign-in, wrong password",
      state: AuthViewState(
        phase: .signInRequired(
          baseUrl: accountsUrl, serverName: "Acme Agents", mode: .accounts, methods: [.password],
          reason: SignInError(
            category: .auth, failure: .signInRequired,
            message: "Sign in again or provide a valid bearer token for this server.",
            serverReason: "invalid username or password")),
        server: accountsServer)),
    AuthSample(
      id: "password-submitting", title: "Accounts sign-in, submitting",
      state: AuthViewState(
        phase: .signingIn(baseUrl: accountsUrl, method: .password), server: accountsServer)),
    AuthSample(
      id: "browser", title: "OIDC browser sign-in",
      state: AuthViewState(
        phase: .signInRequired(
          baseUrl: oidcUrl, serverName: "Example Agents", mode: .oidc, methods: oidcMethods,
          reason: nil),
        server: oidcServer)),
    AuthSample(
      id: "browser-refused", title: "OIDC sign-in refused",
      state: AuthViewState(
        phase: .signInRequired(
          baseUrl: oidcUrl, serverName: "Example Agents", mode: .oidc, methods: oidcMethods,
          reason: SignInError(
            category: .oidc,
            failure: .refused(
              reason:
                "Sign-ins from <b>gmail.com</b> are not allowed. [Request access](https://evil.example)"
            ),
            message:
              "Sign-ins from <b>gmail.com</b> are not allowed. [Request access](https://evil.example)"
          )),
        server: oidcServer)),
    AuthSample(
      id: "signing-in", title: "Signing in",
      state: AuthViewState(
        phase: .signingIn(baseUrl: oidcUrl, method: .loopbackBrowser(path: "/oauth/callback")),
        server: oidcServer)),
    AuthSample(
      id: "ticket", title: "Browser ticket awaiting approval",
      state: AuthViewState(
        phase: .awaitingBrowserLogin(
          baseUrl: oidcUrl,
          login: BrowserApproval(
            loginUrl: "\(oidcUrl)/auth/login?ticket=sample&reauth=1", userCode: "WDJB-MJHT",
            expiresAtMs: 1_793_486_520_000)),
        server: oidcServer)),
    AuthSample(
      id: "reauth-expired", title: "Sign in again: expired",
      state: AuthViewState(
        phase: .signInRequired(
          baseUrl: oidcUrl, serverName: "Example Agents", mode: .oidc, methods: oidcMethods,
          reason: SignInError(
            category: .oidc, failure: .expired,
            message:
              "Your sign-in to omnigent.example.com has expired. Sign in again to continue.")),
        server: oidcServer)),
    AuthSample(
      id: "reauth-ended", title: "Sign in again: ended by server",
      state: AuthViewState(
        phase: .signInRequired(
          baseUrl: oidcUrl, serverName: "Example Agents", mode: .oidc, methods: oidcMethods,
          reason: SignInError(
            category: .oidc, failure: .endedByServer,
            message: "omnigent.example.com ended your session. Sign in again to continue.")),
        server: oidcServer)),
    AuthSample(
      id: "workspace", title: "Databricks workspace",
      state: AuthViewState(
        phase: .signInRequired(
          baseUrl: workspaceUrl, serverName: nil, mode: .proxy,
          methods: [.databricksWorkspace(workspaceHost: "dbc-1234.cloud.databricks.com")],
          reason: nil),
        server: workspaceServer)),
    AuthSample(
      id: "workspace-signing-in", title: "Databricks workspace, signing in",
      state: AuthViewState(
        phase: .signingIn(
          baseUrl: workspaceUrl,
          method: .databricksWorkspace(workspaceHost: "dbc-1234.cloud.databricks.com")),
        server: workspaceServer)),
    AuthSample(
      id: "unsupported", title: "Unsupported mode",
      state: AuthViewState(
        phase: .signInRequired(
          baseUrl: "https://agents.example.org", serverName: "Partner Agents",
          mode: .unsupported(mode: "saml"), methods: [], reason: nil))),
    AuthSample(
      id: "proxy", title: "Proxy mode",
      state: AuthViewState(
        phase: .signInRequired(
          baseUrl: "https://agents.internal.example", serverName: nil, mode: .proxy, methods: [],
          reason: nil))),
    AuthSample(
      id: "connecting", title: "Confirming identity",
      state: AuthViewState(phase: .connecting(baseUrl: oidcUrl), server: oidcServer)),
    AuthSample(
      id: "signed-in", title: "Signed in",
      state: AuthViewState(
        phase: .connected(
          server: SignedInAccount(
            baseUrl: oidcUrl, serverName: "Example Agents", userId: "ada@example.com",
            accountId: "https://omnigent.example.com#ada@example.com", mode: .oidc)))),
  ]

  /// The sample with `id`.
  /// - Parameter id: The sample's identifier.
  /// - Returns: The sample, or `nil` for an unknown identifier.
  public static func sample(_ id: String) -> AuthSample? {
    all.first { $0.id == id }
  }

  /// A connected account, for the chip.
  public static let account = SignedInAccount(
    baseUrl: oidcUrl, serverName: "Example Agents", userId: "ada@example.com",
    accountId: "https://omnigent.example.com#ada@example.com", mode: .oidc)
}
