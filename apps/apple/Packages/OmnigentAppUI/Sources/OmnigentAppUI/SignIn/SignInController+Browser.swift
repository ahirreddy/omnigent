import Foundation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentServices
import OmnigentStores

// The platform half of each browser sign-in: the loopback listener and system browser (macOS,
// OIDC and Databricks), the sign-in sheet for a registered scheme, a Databricks HTTPS callback or
// a Databricks loopback redirect (iOS), and the browser-ticket page. The core runs the protocol;
// failures become the screen's banner.
extension SignInController {
  /// Where a loopback sign-in's page opens.
  enum LoopbackPage {
    /// The system browser, outside the app.
    case systemBrowser
    /// The sign-in sheet, dismissed once the listener receives the redirect.
    case sheet

    static var platformDefault: Self {
      #if os(macOS)
        .systemBrowser
      #else
        .sheet
      #endif
    }
  }

  /// A scheme no page redirects to: the sheet showing a loopback sign-in never intercepts a
  /// callback itself, so the listener receives it.
  static let unmatchedCallbackScheme = "ai.omnigent.loopback-sign-in"

  /// What shows a sign-in page in a sheet and returns the URL it came back to.
  typealias AuthenticateInSheet =
    @MainActor (URL, WebAuthenticationCallback) async throws(WebAuthenticationError) -> URL

  /// The system's web authentication sheet.
  static func systemSheet() -> AuthenticateInSheet {
    let presenter = WebAuthenticationPresenter()
    return { url, callback throws(WebAuthenticationError) in
      try await presenter.authenticate(
        url: url, callback: callback, anchorProvider: KeyWindowAnchorProvider())
    }
  }

  func startBrowserSignIn(_ option: SignInOption) {
    stopBrowserSignIn()
    flowError = nil
    notice = nil
    method = option
    browserTask = Task { [weak self] in
      await self?.runBrowserSignIn(option)
      self?.browserTask = nil
      self?.method = nil
    }
  }

  private func runBrowserSignIn(_ option: SignInOption) async {
    switch option {
    case .loopbackBrowser(let path):
      await loopbackSignIn(path: path)
    case .browser(let redirectUri):
      await sheetSignIn(redirectUri: redirectUri)
    case .browserTicket:
      await ticketSignIn()
    case .password:
      flowError = SignInError(category: .other, message: "Use the password form to sign in.")
    case .databricksWorkspace:
      await databricksSignIn()
    }
  }

  /// The page a challenge names, or why it can't be shown.
  static func signInPage(_ address: String, of owner: String) throws(WebAuthenticationError) -> URL
  {
    guard let url = URL(string: address) else {
      throw .failed(message: "\(owner) sign-in page is not a URL: \(address)")
    }
    return url
  }

  /// Databricks workspace OAuth: a loopback listener when the core's method says so, else the
  /// sign-in sheet intercepting the HTTPS callback it names.
  private func databricksSignIn() async {
    if databricksUsesLoopback {
      await databricksLoopbackSignIn()
      return
    }
    let before = store.issues.count
    guard let challenge = store.beginDatabricksSignIn() else {
      if store.issues.count > before, let issue = store.issues.last {
        flowError = SignInError(issue.error)
      }
      return
    }
    do {
      let url = try Self.signInPage(challenge.authorizeUrl, of: "The workspace")
      let callback = try await authenticateInSheet(
        url, .https(host: challenge.callbackHost, path: challenge.callbackPath))
      let completedBefore = store.issues.count
      let server = await store.completeDatabricksSignIn(challenge, callbackURL: callback)
      signedIn(server, issuesBefore: completedBefore)
    } catch {
      store.cancelDatabricksSignIn(challenge)
      switch error {
      case .cancelled: notice = "Sign-in was cancelled."
      case .failed(let message): flowError = SignInError(category: .oidc, message: message)
      }
    }
  }

  /// Whether the core offers Databricks sign-in through the loopback redirect.
  private var databricksUsesLoopback: Bool {
    guard case .signInRequired(_, _, _, let methods, _) = store.phase else { return false }
    return methods.contains { method in
      if case .databricksWorkspace(_, let loopback, _, _) = method { loopback } else { false }
    }
  }

  /// The challenge for the listener's port; without one, stops listening and says why.
  func beginDatabricks(
    port: UInt16, listener: LoopbackRedirectListener
  ) -> DatabricksChallenge? {
    let before = store.issues.count
    if let challenge = store.beginDatabricksSignIn(loopbackPort: port) { return challenge }
    listener.cancel()
    if store.issues.count > before, let issue = store.issues.last {
      flowError = SignInError(issue.error)
    }
    return nil
  }

  /// Databricks through the published client's `http://localhost` redirect, received on an
  /// ephemeral loopback port (RFC 8252); the page opens where ``databricksLoopbackPage`` says.
  private func databricksLoopbackSignIn() async {
    let listener = makeListener()
    self.listener = listener
    let port: UInt16
    do {
      port = try Self.loopbackPort(
        of: try await listener.start(path: "/", host: "localhost"))
    } catch {
      listener.cancel()
      flowError = Self.listenerError(error)
      return
    }
    guard let challenge = beginDatabricks(port: port, listener: listener) else { return }
    switch databricksLoopbackPage {
    case .systemBrowser:
      await databricksInBrowser(challenge, listener: listener)
    case .sheet:
      await databricksInSheet(challenge, listener: listener)
    }
  }

  private func databricksInBrowser(
    _ challenge: DatabricksChallenge, listener: LoopbackRedirectListener
  ) async {
    guard await openInBrowser(challenge.authorizeUrl) else {
      store.cancelDatabricksSignIn(challenge)
      listener.cancel()
      return
    }
    do {
      let callback = try await listener.waitForCallback()
      await completeDatabricks(challenge, callbackURL: callback)
    } catch {
      store.cancelDatabricksSignIn(challenge)
      if error != .cancelled { flowError = Self.listenerError(error) }
    }
  }

  /// The page in the sign-in sheet while the listener waits; whichever ends first decides, and
  /// the other is stopped (a received redirect dismisses the sheet).
  private func databricksInSheet(
    _ challenge: DatabricksChallenge, listener: LoopbackRedirectListener
  ) async {
    let page: URL
    do {
      page = try Self.signInPage(challenge.authorizeUrl, of: "The workspace")
    } catch {
      listener.cancel()
      store.cancelDatabricksSignIn(challenge)
      switch error {
      case .cancelled: notice = "Sign-in was cancelled."
      case .failed(let message): flowError = SignInError(category: .oidc, message: message)
      }
      return
    }
    let outcome = await Self.firstOf(
      listener: listener, sheet: authenticateInSheet, page: page,
      callback: .customScheme(Self.unmatchedCallbackScheme))
    if case .redirect(let callback) = outcome {
      await completeDatabricks(challenge, callbackURL: callback)
      return
    }
    store.cancelDatabricksSignIn(challenge)
    switch outcome {
    case .redirect, .listenerEnded(.cancelled):
      return
    case .listenerEnded(let error):
      flowError = Self.listenerError(error)
    case .sheetEnded(.cancelled):
      if !Task.isCancelled { notice = "Sign-in was cancelled." }
    case .sheetEnded(.failed(let message)):
      flowError = SignInError(category: .oidc, message: message)
    case .sheetReturned(let url):
      flowError = SignInError(
        category: .oidc, message: "The sign-in sheet returned an unexpected page: \(url)")
    }
  }

  /// How a loopback sign-in shown in the sheet ended.
  enum LoopbackSheetOutcome: Equatable {
    /// The listener received the redirect.
    case redirect(URL)
    /// The listener stopped first.
    case listenerEnded(LoopbackRedirectError)
    /// The sheet closed first: the user dismissed it, or it failed.
    case sheetEnded(WebAuthenticationError)
    /// The sheet intercepted a callback, which its unmatched scheme should never allow.
    case sheetReturned(URL)
  }

  /// Runs the listener's wait and the sheet together, and stops the one still running once the
  /// other ends.
  static func firstOf(
    listener: LoopbackRedirectListener, sheet: @escaping AuthenticateInSheet, page: URL,
    callback: WebAuthenticationCallback
  ) async -> LoopbackSheetOutcome {
    await withTaskGroup(of: LoopbackSheetOutcome.self) { group in
      group.addTask { await redirectOutcome(listener) }
      group.addTask { await sheetOutcome(sheet, page: page, callback: callback) }
      let first = await group.next() ?? .listenerEnded(.cancelled)
      group.cancelAll()
      return first
    }
  }

  private static func redirectOutcome(
    _ listener: LoopbackRedirectListener
  ) async -> LoopbackSheetOutcome {
    do {
      return .redirect(try await listener.waitForCallback())
    } catch {
      return .listenerEnded(error)
    }
  }

  private static func sheetOutcome(
    _ sheet: AuthenticateInSheet, page: URL, callback: WebAuthenticationCallback
  ) async -> LoopbackSheetOutcome {
    do {
      return .sheetReturned(try await sheet(page, callback))
    } catch {
      return .sheetEnded(error)
    }
  }

  private func completeDatabricks(_ challenge: DatabricksChallenge, callbackURL: URL) async {
    let before = store.issues.count
    let server = await store.completeDatabricksSignIn(challenge, callbackURL: callbackURL)
    signedIn(server, issuesBefore: before)
  }

  private func loopbackSignIn(path: String) async {
    #if os(macOS)
      let listener = makeListener()
      self.listener = listener
      let redirect: URL
      do {
        redirect = try await listener.start(path: path)
      } catch {
        flowError = Self.listenerError(error)
        return
      }
      guard let challenge = begin(redirectURI: redirect.absoluteString) else { return }
      guard await openInBrowser(challenge.authorizeUrl) else {
        store.cancelBrowserSignIn(challenge)
        listener.cancel()
        return
      }
      do {
        let callback = try await listener.waitForCallback()
        await complete(challenge, callbackURL: callback)
      } catch {
        store.cancelBrowserSignIn(challenge)
        if error != .cancelled { flowError = Self.listenerError(error) }
      }
    #else
      flowError = SignInError(
        category: .other, message: "Loopback sign-in is only available on macOS (path \(path)).")
    #endif
  }

  private func sheetSignIn(redirectUri: String) async {
    guard let challenge = begin(redirectURI: redirectUri) else { return }
    do {
      let url = try Self.signInPage(challenge.authorizeUrl, of: "The server's")
      let callback = try await authenticateInSheet(url, .customScheme(challenge.callbackScheme))
      await complete(challenge, callbackURL: callback)
    } catch {
      store.cancelBrowserSignIn(challenge)
      switch error {
      case .cancelled: notice = "Sign-in was cancelled."
      case .failed(let message): flowError = SignInError(category: .oidc, message: message)
      }
    }
  }

  private func ticketSignIn() async {
    let before = store.issues.count
    await store.beginBrowserTicketSignIn()
    guard let login = store.browserLogin else {
      if store.issues.count > before, let issue = store.issues.last {
        flowError = SignInError(issue.error)
      }
      return
    }
    guard await openInBrowser(login.loginUrl) else { return }
    method = nil
    await finishTicketSignIn()
  }

  /// The core polls the ticket itself and reports only through the phase, so a sign-in finished
  /// that way still has to be remembered and handed to the window.
  private func finishTicketSignIn() async {
    while store.browserLogin != nil {
      do {
        try await Task.sleep(for: .milliseconds(100))
      } catch {
        return
      }
    }
    if case .connected(let server) = store.phase {
      signedIn(server, issuesBefore: store.issues.count)
    }
  }

  private func begin(redirectURI: String) -> OidcChallenge? {
    let before = store.issues.count
    guard let challenge = store.beginBrowserSignIn(redirectURI: redirectURI) else {
      if store.issues.count > before, let issue = store.issues.last {
        flowError = SignInError(issue.error)
      }
      return nil
    }
    self.challenge = challenge
    return challenge
  }

  private func complete(_ challenge: OidcChallenge, callbackURL: URL) async {
    let before = store.issues.count
    let server = await store.completeBrowserSignIn(challenge, callbackURL: callbackURL)
    self.challenge = nil
    signedIn(server, issuesBefore: before)
  }

  private func openInBrowser(_ address: String) async -> Bool {
    guard let url = URL(string: address), await opener.open(url) else {
      flowError = SignInError(
        category: .other, message: "Could not open the sign-in page in your browser: \(address)")
      return false
    }
    return true
  }

  func stopBrowserSignIn() {
    browserTask?.cancel()
    browserTask = nil
    listener?.cancel()
    listener = nil
    if let challenge {
      store.cancelBrowserSignIn(challenge)
      self.challenge = nil
    }
  }

  /// The port a listener's address names, or why it names none.
  static func loopbackPort(of redirect: URL) throws(LoopbackRedirectError) -> UInt16 {
    guard let port = redirect.port.flatMap({ UInt16(exactly: $0) }) else {
      throw .failed(message: "The sign-in listener has no port: \(redirect.absoluteString)")
    }
    return port
  }

  static func listenerError(_ error: LoopbackRedirectError) -> SignInError {
    let detail =
      switch error {
      case .failed(let message): message
      case .cancelled: "The sign-in was cancelled."
      case .alreadyStarted, .notStarted, .alreadyWaiting:
        "The sign-in listener is busy (\(error))."
      }
    return SignInError(
      category: .oidc, message: "Could not receive the browser sign-in: \(detail)")
  }
}
