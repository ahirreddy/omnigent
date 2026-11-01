public import Foundation
public import Observation
public import OmnigentAuthUI
import OmnigentCoreFFI
public import OmnigentStores
import OmnigentServices

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

  /// Removes a server from the recents.
  @ObservationIgnored public var forgetServer: @MainActor (String) -> Void = { _ in }
  /// Called after a connect resolved the canonical server, and when the user leaves a server
  /// for the picker (`nil`).
  @ObservationIgnored public var onServerChange: @MainActor (URL?) -> Void = { _ in }

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
      phase: phase, server: nil, directory: directory, lastServerUrl: lastServerUrl,
      notice: notice)
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
      forgetServer: { [weak self] in self?.forgetServer($0) })
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

  /// Connects to `serverURL` as typed. The core normalizes it, discovers the server, restores a
  /// saved sign-in when there is one, and reports progress through the phase.
  /// - Parameter serverURL: The server as typed.
  public func connect(_ serverURL: String) {
    let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    lastServerUrl = trimmed
    notice = nil
    flowError = nil
    method = nil
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
    case .signInRequired(let url, _, _, _, _):
      baseUrl = url
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
      await store.signIn(username: credentials.username, password: credentials.password)
      method = nil
      if case .connected(let server) = store.phase {
        accounts.remember(server)
      } else if store.issues.count > before, let issue = store.issues.last {
        flowError = SignInError(issue.error)
      }
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
