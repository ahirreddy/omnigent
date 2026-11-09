public import Foundation
public import Observation
public import OmnigentAuthUI
public import OmnigentCoreFFI
import OmnigentServices
public import OmnigentStores

/// Drives the sign-in UI for one ``ConnectionStore``: it builds ``AuthViewState`` from the
/// core's phase and runs the platform half of each sign-in (the loopback listener and system
/// browser on macOS, the sign-in sheet for a registered scheme, the browser-ticket page).
///
/// Every failure is shown: the core reports most through the phase; failures outside it (the
/// listener, the sheet, a refused start) become the sign-in screen's banner.
@Observable
public final class SignInController {
  /// The store this controller signs in.
  public let store: ConnectionStore
  /// The servers the picker offers.
  public var directory = ServerDirectory()
  /// The last server the user tried, kept on cancel and failure to prefill the picker.
  public private(set) var lastServerUrl: String?
  /// A one-off informational message, for example after signing out.
  public internal(set) var notice: String?
  /// A failure outside the core's phase, shown on the sign-in screen.
  public internal(set) var flowError: SignInError?
  /// The sign-in this controller started, while it runs.
  public internal(set) var method: SignInOption?
  /// Whether the accounts screen signs in or creates an account.
  public internal(set) var accountForm = AccountForm.signIn
  /// The server being signed in to, when it has no administrator yet.
  public internal(set) var unclaimedServer: ServerIdentity?
  /// An invite link that opened the app: Create Account opens with it until signed in.
  public internal(set) var inviteLink: String?
  /// This Mac's local server for "Get started locally"; `nil` where it cannot run.
  @ObservationIgnored public var localSetup: (any LocalSetupSource)?

  /// Removes a server from the recents.
  @ObservationIgnored public var forgetServer: @MainActor (String) -> Void = { _ in }
  /// Called after a connect resolved the canonical server, and when the user leaves a server
  /// for the picker (`nil`).
  @ObservationIgnored public var onServerChange: @MainActor (URL?) -> Void = { _ in }
  /// Called once a connect, restore or sign-in reaches a signed-in server, from that call's own
  /// result rather than ``ConnectionStore/phase``, which the core's event can update later.
  @ObservationIgnored public var onSignedIn: @MainActor (ConnectedServer) -> Void = { _ in }

  @ObservationIgnored let opener: ExternalURLOpener
  @ObservationIgnored let accounts: RememberedAccounts
  @ObservationIgnored var browserTask: Task<Void, Never>?
  @ObservationIgnored var challenge: OidcChallenge?
  #if os(macOS)
    @ObservationIgnored var listener: LoopbackRedirectListener?
  #endif
  @ObservationIgnored let presenter = WebAuthenticationPresenter()

  /// Creates a controller.
  /// - Parameters:
  ///   - store: The connection to sign in.
  ///   - opener: Opens pages in the system browser.
  ///   - defaults: Where the last account per server is remembered (accounts mode).
  public init(
    store: ConnectionStore, opener: ExternalURLOpener = .system,
    defaults: UserDefaults = .standard
  ) {
    self.store = store
    self.opener = opener
    accounts = RememberedAccounts(defaults: defaults)
  }

  /// Everything the sign-in UI renders.
  public var state: AuthViewState {
    AuthViewState(
      phase: phase, server: unclaimedServer, directory: directory, lastServerUrl: lastServerUrl,
      notice: notice, accountForm: accountForm, localSetup: localSetup?.state,
      inviteLink: inviteLink)
  }

  /// The actions the sign-in UI calls.
  public var actions: AuthActions {
    AuthActions(
      connect: { [weak self] in self?.connect($0) },
      submitCredentials: { [weak self] in self?.submit($0) },
      startBrowserSignIn: { [weak self] in self?.startBrowserSignIn($0) },
      cancel: { [weak self] in self?.cancel() },
      signOut: { [weak self] in self?.signOut() },
      retry: { [weak self] in self?.retry() },
      forgetServer: { [weak self] in self?.forgetServer($0) },
      createAccount: { [weak self] in self?.createAccount($0) },
      showAccountForm: { [weak self] in self?.showAccountForm($0) },
      inviteToken: { inviteTokenFromLink(text: $0) },
      checkServer: { [weak self] in await self?.checkServer($0) ?? .unreachable },
      localSetup: localSetup?.actions(connect: { [weak self] in self?.connect($0) }))
  }

  private var phase: SignInPhase {
    let phase = SignInPhase(store.phase, method: method)
    guard let flowError else { return phase }
    switch phase {
    case .signInRequired(let baseUrl, let serverName, let mode, let methods, let reason):
      return .signInRequired(
        baseUrl: baseUrl, serverName: serverName, mode: mode, methods: methods,
        reason: reason ?? flowError)
    case .disconnected:
      return .failed(serverUrl: lastServerUrl ?? "", error: flowError)
    case .signingIn(let baseUrl, _) where browserTask == nil && method == nil:
      // A sign-in that failed after the server accepted it (for example saving the credential)
      // leaves the core's phase at signing in; show the failure instead of a spinner.
      return .failed(serverUrl: baseUrl, error: flowError)
    default:
      return phase
    }
  }

  /// Starts this Mac's server and connects to it, when it is the server last used.
  public func resumeLocalServer() {
    guard let localSetup, let last = directory.recentServers.first,
      LocalInstall.isLocalInstall(last)
    else { return }
    localSetup.actions(connect: { [weak self] in self?.connect($0) }).start()
  }

  /// Connects to `serverURL` as typed. The core normalizes it, discovers the server, restores a
  /// saved sign-in when there is one, and reports progress through the phase.
  /// - Parameter serverURL: The server as typed.
  public func connect(_ serverURL: String) {
    var trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    inviteLink = nil
    // A pasted invite link connects to its server and opens Create Account with it.
    if let server = Self.inviteServer(trimmed) {
      inviteLink = trimmed
      trimmed = server
    }
    lastServerUrl = trimmed
    notice = nil
    flowError = nil
    method = nil
    accountForm = inviteLink == nil ? .signIn : .register
    unclaimedServer = nil
    Task { await connectNow(trimmed) }
  }

  /// Connects and waits for the outcome.
  /// - Parameter serverURL: The server as typed.
  public func connectNow(_ serverURL: String) async {
    guard let core = store.core else {
      flowError = store.issues.last.map { SignInError($0.error) }
      return
    }
    lastServerUrl = serverURL
    do {
      let phase = try await core.connect(
        serverUrl: serverURL, expectedUserId: accounts.user(for: serverURL))
      resolved(phase)
    } catch let error as CoreError {
      // A newer connect replaced this one; its own outcome is what the user sees.
      if case .InvalidState = error, store.phase != .disconnected { return }
      // The core moves the phase to `failed` with this error; keep it visible if it did not.
      if case .failed = store.phase { return }
      flowError = SignInError(error)
    } catch {
      flowError = SignInError(.InvalidState(message: String(describing: error)))
    }
  }

  private func resolved(_ phase: ConnectionPhase) {
    let baseUrl: String
    switch phase {
    case .connected(let server):
      baseUrl = server.baseUrl
      accounts.remember(server)
      if let url = URL(string: baseUrl) { onServerChange(url) }
      signedInHere(server)
      return
    case .signInRequired(let url, _, _, _, _):
      baseUrl = url
      let needsSetup = store.core?.needsAccountSetup() ?? false
      unclaimedServer = needsSetup ? ServerIdentity(baseUrl: url, needsSetup: true) : nil
      accountForm = needsSetup ? .createAdmin : inviteLink == nil ? .signIn : .register
    default:
      return
    }
    if let url = URL(string: baseUrl) { onServerChange(url) }
  }

  private func submit(_ credentials: AccountCredentials) {
    flowError = nil
    notice = nil
    method = .password
    Task {
      let before = store.issues.count
      let server = await store.signIn(
        username: credentials.username, password: credentials.password)
      method = nil
      signedIn(server, issuesBefore: before)
    }
  }

  /// Finishes a sign-in: remembers the account so the next launch restores it, or shows the
  /// failure the store recorded.
  ///
  /// The server comes from the sign-in's own result, not ``ConnectionStore/phase``: the core's
  /// `connected` event can land after the call returns, and reading the phase then skipped
  /// remembering the account, so the next launch asked for the password again.
  /// - Parameters:
  ///   - server: The server signed in to, or `nil` when the sign-in failed.
  ///   - issuesBefore: The store's issue count before the sign-in started.
  func signedIn(_ server: ConnectedServer?, issuesBefore: Int) {
    if let server {
      accounts.remember(server)
      signedInHere(server)
    } else if store.issues.count > issuesBefore, let issue = store.issues.last {
      flowError = SignInError(issue.error)
    }
  }

  private func retry() {
    guard let lastServerUrl else { return }
    connect(lastServerUrl)
  }

  private func signOut() {
    let host = store.connectedServer.map { ServerIdentity.hostLabel($0.baseUrl) }
    if let server = store.connectedServer { accounts.forget(server.baseUrl) }
    Task {
      let before = store.issues.count
      await store.signOut()
      if store.issues.count > before, let issue = store.issues.last {
        flowError = SignInError(issue.error)
      } else {
        notice = host.map { "You\u{2019}re signed out of \($0)." } ?? "You\u{2019}re signed out."
      }
    }
  }

  /// Stops the work in flight, or leaves a sign-in form for the server picker.
  private func cancel() {
    let wasSigningIn = browserTask != nil
    stopBrowserSignIn()
    flowError = nil
    method = nil
    switch store.phase {
    case .signingIn where wasSigningIn:
      notice = "Sign-in was cancelled."
    case .connected:
      return
    default:
      store.disconnect()
      onServerChange(nil)
    }
  }
}
