import Foundation
import Testing

@testable import OmnigentAuthUI

/// Small facts about the sign-in model that no screen reaches on its own.
@Suite("Auth model edges")
struct AuthModelEdgeTests {
  @Test("every phase names its server, and being disconnected names none")
  func phaseServers() {
    let approval = BrowserApproval(loginUrl: "https://a.test/login", expiresAtMs: 0)
    let account = SignedInAccount(
      baseUrl: "https://a.test", serverName: nil, userId: "ada", accountId: "1", mode: .oidc)
    let phases: [SignInPhase] = [
      .discovering(serverUrl: "https://a.test"),
      .signInRequired(
        baseUrl: "https://a.test", serverName: nil, mode: .oidc, methods: [], reason: nil),
      .signingIn(baseUrl: "https://a.test"),
      .awaitingBrowserLogin(baseUrl: "https://a.test", login: approval),
      .connecting(baseUrl: "https://a.test"),
      .connected(server: account),
      .failed(
        serverUrl: "https://a.test",
        error: SignInError(category: .transport, message: "no")),
    ]
    for phase in phases { #expect(phase.serverUrl == "https://a.test", "\(phase)") }
    #expect(SignInPhase.disconnected.serverUrl == nil)
  }

  @Test("a pairing code's errors read as sentences, and a bad server keeps the core's words")
  func pairingMessages() {
    #expect(PairingCodeError.notAPairingCode.message == "This isn't an Omnigent pairing code.")
    #expect(PairingCodeError.unsupportedVersion.message.contains("newer version"))
    #expect(PairingCodeError.missingServer.message.contains("no server address"))
    #expect(PairingCodeError.invalidServer("https only").message == "https only")
  }

  @Test("each sign-in option says whether it opens a browser")
  func optionsUseBrowser() {
    #expect(!SignInOption.password.usesBrowser)
    for option in [
      SignInOption.browser(redirectUri: "x"), .loopbackBrowser(path: "/cb"), .browserTicket,
      .databricksWorkspace(workspaceHost: "h"),
    ] {
      #expect(option.usesBrowser, "\(option)")
    }
  }

  @Test("line separators can't break a server's words across lines")
  func lineSeparators() {
    #expect(!ServerText.escaped("one\u{2028}two").contains("\u{2028}"))
    #expect(!ServerText.escaped("one\u{2029}two").contains("\u{2029}"))
  }

  @Test("a directory knows when it offers nothing, and a confirmation is known by its URL")
  func identities() {
    #expect(ServerDirectory().isEmpty)
    #expect(!ServerDirectory(recentServers: ["https://a.test"]).isEmpty)
    let confirmation = PairingConfirmation(
      serverURL: "https://a.test", host: "a.test", isLoopback: false)
    #expect(confirmation.id == "https://a.test")
  }

  @Test("the stand-in invite parser takes a link's invite or a bare token")
  func inviteTokens() {
    #expect(AuthActions.previewInviteToken("") == nil)
    #expect(AuthActions.previewInviteToken("abc") == "abc")
    #expect(AuthActions.previewInviteToken("two words") == nil)
    #expect(AuthActions.previewInviteToken("https://a.test/j?invite=xyz") == "xyz")
    #expect(AuthActions.previewInviteToken("https://a.test/j?invite=") == nil)
  }
}
