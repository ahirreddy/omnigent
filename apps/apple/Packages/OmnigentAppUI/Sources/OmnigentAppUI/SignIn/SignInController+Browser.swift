import Foundation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentServices
import OmnigentStores

// The platform half of each browser sign-in: the loopback listener and system browser (macOS),
// the sign-in sheet for a registered scheme or a Databricks HTTPS callback, and the
// browser-ticket page. The core runs the protocol; failures become the screen's banner.
extension SignInController {
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

  /// Databricks workspace OAuth: the sign-in sheet intercepts the HTTPS callback the core names.
  private func databricksSignIn() async {
    let before = store.issues.count
    guard let challenge = store.beginDatabricksSignIn() else {
      if store.issues.count > before, let issue = store.issues.last {
        flowError = SignInError(issue.error)
      }
      return
    }
    guard let url = URL(string: challenge.authorizeUrl) else {
      store.cancelDatabricksSignIn(challenge)
      flowError = SignInError(
        category: .oidc,
        message: "The workspace sign-in page is not a URL: \(challenge.authorizeUrl)")
      return
    }
    do {
      let callback = try await presenter.authenticate(
        url: url, callback: .https(host: challenge.callbackHost, path: challenge.callbackPath),
        anchorProvider: KeyWindowAnchorProvider())
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

  private func loopbackSignIn(path: String) async {
    #if os(macOS)
      let listener = LoopbackRedirectListener()
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
    guard let url = URL(string: challenge.authorizeUrl) else {
      store.cancelBrowserSignIn(challenge)
      flowError = SignInError(
        category: .oidc, message: "The server's sign-in page is not a URL: \(challenge.authorizeUrl)")
      return
    }
    do {
      let callback = try await presenter.authenticate(
        url: url, callback: .customScheme(challenge.callbackScheme),
        anchorProvider: KeyWindowAnchorProvider())
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
    _ = await openInBrowser(login.loginUrl)
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
    #if os(macOS)
      listener?.cancel()
      listener = nil
    #endif
    if let challenge {
      store.cancelBrowserSignIn(challenge)
      self.challenge = nil
    }
  }

  #if os(macOS)
    private static func listenerError(_ error: LoopbackRedirectError) -> SignInError {
      let detail =
        switch error {
        case .failed(let message): message
        case .cancelled: "The sign-in was cancelled."
        case .alreadyStarted, .notStarted, .alreadyWaiting: "The sign-in listener is busy (\(error))."
        }
      return SignInError(
        category: .oidc, message: "Could not receive the browser sign-in: \(detail)")
    }
  #endif
}
