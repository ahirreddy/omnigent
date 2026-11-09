#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentAuthUI

  /// Every screen around a browser sign-in: its buttons reach the store, and it says what's going on.
  @MainActor
  @Suite("Browser sign-in screens", .serialized)
  struct BrowserSignInTests {
    private let server = AuthSamples.oidcServer

    @Test("the browser screen starts the best option, and an alternative starts itself")
    func browserOptions() throws {
      let spy = AuthSpy()
      let screen = OffscreenWindow(
        BrowserSignInView(
          server: server, option: .loopbackBrowser(path: "/cb"), alternatives: [.browserTicket],
          banner: nil, actions: spy.actions()),
        width: 560, height: 560)
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.contains("saved passwords and passkeys"))
      #expect(text.contains("Example Agents"))
      try screen.clickFromEnd()
      #expect(spy.browserOptions == [.loopbackBrowser(path: "/cb")])
      try screen.clickFromEnd(1)
      #expect(spy.log == ["cancel"])
      try screen.clickFromEnd(2)
      #expect(spy.browserOptions.last == .browserTicket)
    }

    @Test("a browser-link sign-in explains the approval page, and a refusal shows with Retry")
    func ticketAndRefusal() throws {
      let spy = AuthSpy()
      let failure = SignInError(
        category: .transport, message: "Couldn\u{2019}t reach the sign-in page.")
      let screen = OffscreenWindow(
        BrowserSignInView(
          server: server, option: .browserTicket, alternatives: [], banner: .error(failure),
          actions: spy.actions()),
        width: 560, height: 560)
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.contains("Approve the request there"))
      #expect(text.contains("Couldn\u{2019}t reach the sign-in page."))
      try screen.clickFromEnd(2)
      #expect(spy.log == ["retry"])
    }

    @Test(
      "signing in names where to finish, and Cancel leaves",
      arguments: [
        (SignInOption?.some(.browserTicket), "in the browser window."),
        (SignInOption?.some(.password), "Signing in to Example Agents."),
        (SignInOption?.none, "Signing in to Example Agents."),
      ])
    func signingIn(option: SignInOption?, expected: String) throws {
      let spy = AuthSpy()
      let screen = OffscreenWindow(
        SigningInView(server: server, option: option, actions: spy.actions()),
        width: 560, height: 420)
      defer { screen.close() }
      #expect(try screen.allText().contains(expected))
      try screen.clickFromEnd()
      #expect(spy.log == ["cancel"])
    }

    @Test("approving shows the code, and Open Sign-In Page opens the ticket's page")
    func approval() throws {
      let spy = AuthSpy()
      let approval = BrowserApproval(
        loginUrl: "https://omnigent.example.com/login?ticket=abc", userCode: "WXYZ-1234",
        expiresAtMs: 1_793_502_799_000)
      let screen = OffscreenWindow(
        BrowserApprovalView(server: server, approval: approval, actions: spy.actions())
          .environment(\.openURL, spy.openURL),
        width: 560, height: 560)
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.contains("WXYZ-1234"))
      #expect(text.contains("Waiting for approval"))
      #expect(!text.contains("ticket=abc"), "the ticket is never printed")
      try screen.clickFromEnd()
      #expect(spy.opened.map(\.absoluteString) == [approval.loginUrl])
      try screen.clickFromEnd(1)
      #expect(spy.log == ["cancel"])
    }

    @Test("an approval without a code doesn't ask to match one")
    func approvalWithoutCode() throws {
      let spy = AuthSpy()
      let approval = BrowserApproval(
        loginUrl: "https://omnigent.example.com/login", userCode: "",
        expiresAtMs: 1_793_502_799_000)
      let screen = OffscreenWindow(
        BrowserApprovalView(server: server, approval: approval, actions: spy.actions()),
        width: 560, height: 560)
      defer { screen.close() }
      #expect(try !screen.allText().contains("Confirm the page shows this code"))
    }

    @Test("an unusable approval link turns Open Sign-In Page off")
    func approvalWithBadLink() throws {
      let spy = AuthSpy()
      let approval = BrowserApproval(loginUrl: "", userCode: nil, expiresAtMs: 1_793_502_799_000)
      let screen = OffscreenWindow(
        BrowserApprovalView(server: server, approval: approval, actions: spy.actions())
          .environment(\.openURL, spy.openURL),
        width: 560, height: 560)
      defer { screen.close() }
      try screen.clickFromEnd()
      #expect(spy.opened.isEmpty)
      #expect(spy.log == ["cancel"], "only Cancel takes a click")
    }

    @Test("signing in again names the cause, and only Sign In opens the browser")
    func reauth() throws {
      let spy = AuthSpy()
      let cause = ReauthCause(failure: .expired, message: "Your session on this server expired.")
      let screen = OffscreenWindow(
        ReauthPromptView(
          server: server, cause: cause, option: .browserTicket, actions: spy.actions()),
        width: 560, height: 480)
      defer { screen.close() }
      #expect(try screen.allText().contains("Your session on this server expired."))
      try screen.clickFromEnd(1)
      #expect(spy.log == ["cancel"])
      #expect(spy.browserOptions.isEmpty)
      try screen.clickFromEnd()
      #expect(spy.browserOptions == [.browserTicket])
    }

    @Test("Databricks sign-in names the workspace, starts it and offers Retry on failure")
    func workspace() throws {
      let spy = AuthSpy()
      let host = "dbc-1234.cloud.databricks.com"
      let screen = OffscreenWindow(
        WorkspaceSignInView(
          server: AuthSamples.workspaceServer, workspaceHost: host,
          banner: .error(SignInError(category: .transport, message: "No route to workspace.")),
          isSigningIn: false, actions: spy.actions()),
        width: 560, height: 560)
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.contains("Sign in with Databricks"))
      #expect(text.contains("Databricks workspace \(host)"))
      #expect(text.contains("No route to workspace."))
      try screen.clickFromEnd()
      #expect(spy.browserOptions == [.databricksWorkspace(workspaceHost: host)])
      try screen.clickFromEnd(1)
      #expect(spy.log == ["cancel"])
      try screen.clickFromEnd(2)
      #expect(spy.log.last == "retry")
    }

    @Test("while Databricks is open only Cancel is offered")
    func workspaceWaiting() throws {
      let spy = AuthSpy()
      let screen = OffscreenWindow(
        WorkspaceSignInView(
          server: AuthSamples.workspaceServer, workspaceHost: "dbc.example.com", banner: nil,
          isSigningIn: true, actions: spy.actions()),
        width: 560, height: 480)
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.contains("Waiting for Databricks"))
      #expect(text.contains("Finish signing in to dbc.example.com"))
      #expect(screen.controlFrames.count == 1)
      try screen.clickFromEnd()
      #expect(spy.log == ["cancel"])
      #expect(spy.browserOptions.isEmpty)
    }

    @Test("connecting names the host and Cancel stops it")
    func connecting() throws {
      let spy = AuthSpy()
      let screen = OffscreenWindow(
        ConnectingView(
          title: "Connecting\u{2026}", serverUrl: "https://agents.example.com/path",
          actions: spy.actions()),
        width: 560, height: 360)
      defer { screen.close() }
      #expect(try screen.allText().contains("agents.example.com"))
      try screen.clickFromEnd()
      #expect(spy.log == ["cancel"])
    }

    @Test(
      "a server this app can't sign in to says why",
      arguments: [
        (SignInMode.proxy, "from a proxy"),
        (SignInMode.unsupported(mode: "saml"), "\u{201C}saml\u{201D}"),
        (SignInMode.oidc, "can\u{2019}t offer a sign-in method"),
      ])
    func unsupported(mode: SignInMode, expected: String) throws {
      let spy = AuthSpy()
      let screen = OffscreenWindow(
        UnsupportedModeView(server: server, mode: mode, actions: spy.actions())
          .environment(\.openURL, spy.openURL),
        width: 560, height: 480)
      defer { screen.close() }
      #expect(try screen.allText().contains(expected))
      try screen.clickFromEnd()
      #expect(spy.opened == [server.webURL].compactMap(\.self))
      #expect(!spy.opened.isEmpty)
      try screen.clickFromEnd(1)
      #expect(spy.log == ["cancel"])
    }
  }

  /// The account chip's menu and the signed-in screen.
  @MainActor
  @Suite("Signed-in account", .serialized)
  struct SignedInAccountTests {
    private func account(canSignOut: Bool = true, name: String? = "Example Agents")
      -> SignedInAccount
    {
      SignedInAccount(
        baseUrl: AuthSamples.oidcUrl, serverName: name, userId: "ada", accountId: "a1",
        mode: canSignOut ? .oidc : .localSingleUser)
    }

    @Test("the chip's menu names the account and server and signs out")
    func chipMenu() throws {
      let spy = AuthSpy()
      let screen = OffscreenWindow(
        AccountChip(account: account(), actions: spy.actions()), width: 320, height: 120)
      defer { screen.close() }
      #expect(try screen.allText().contains("Example Agents"))
      let chip = try #require(screen.controlFrames.first)
      let menu = try screen.openMenu(CGPoint(x: chip.midX, y: chip.midY))
      let titles = menu.items.map(\.title)
      #expect(titles.contains("Signed in as ada"))
      #expect(titles.contains("Example Agents"))
      #expect(titles.contains("omnigent.example.com"))
      try screen.choose("Sign Out", in: menu)
      #expect(spy.log == ["signOut"])
    }

    @Test("a local account can't sign out, and a server named after its host isn't said twice")
    func chipWithoutSignOut() throws {
      let spy = AuthSpy()
      let screen = OffscreenWindow(
        AccountChip(account: account(canSignOut: false, name: nil), actions: spy.actions()),
        width: 320, height: 120)
      defer { screen.close() }
      let chip = try #require(screen.controlFrames.first)
      let titles = try screen.openMenu(CGPoint(x: chip.midX, y: chip.midY)).items.map(\.title)
      #expect(!titles.contains("Sign Out"))
      #expect(titles.filter { $0 == "omnigent.example.com" }.count == 1)
    }

    @Test("the chip's initial is the user's first letter or digit, else a question mark")
    func initials() throws {
      for (user, initial) in [("ada", "A"), ("__7x", "7"), ("---", "?")] {
        var named = account()
        named.userId = user
        let screen = OffscreenWindow(AccountChipLabel(account: named), width: 320, height: 80)
        defer { screen.close() }
        #expect(try screen.shownText().contains(initial), "\(user)")
      }
    }

    @Test("signed in says where, and Sign Out shows only when it can")
    func signedIn() throws {
      let spy = AuthSpy()
      let screen = OffscreenWindow(
        SignedInView(account: account(), actions: spy.actions()), width: 560, height: 420)
      defer { screen.close() }
      #expect(try screen.allText().contains("connected to Example Agents"))
      try screen.clickFromEnd()
      #expect(spy.log == ["signOut"])
      let local = OffscreenWindow(
        SignedInView(account: account(canSignOut: false), actions: spy.actions()),
        width: 560, height: 420)
      defer { local.close() }
      #expect(local.controlFrames.count == screen.controlFrames.count - 1)
    }
  }
#endif
