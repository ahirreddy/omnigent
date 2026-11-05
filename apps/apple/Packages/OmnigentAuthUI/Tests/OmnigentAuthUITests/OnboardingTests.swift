import Foundation
import Testing

@testable import OmnigentAuthUI

private let remote = "https://omnigent.example.com"
private let localInstall = "http://127.0.0.1:6767"
private let localSetup = LocalSetupState(cli: .found, server: .stopped)

private func managed(_ url: String) -> ManagedServerEntry {
  ManagedServerEntry(
    url: url, name: "Acme", origin: url, authority: "omnigent.example.com", displayName: "Acme")
}

struct OnboardingStepTests {
  @Test func newUsersOnAMacThatCanRunLocallySeeTheLanding() {
    let step = OnboardingStep.initial(
      directory: ServerDirectory(), banner: nil, offersLocalSetup: true)
    #expect(step == .landing)
  }

  @Test func returningUsersAndFailuresOpenTheServerList() {
    let returning = ServerDirectory(recentServers: [remote])
    #expect(
      OnboardingStep.initial(directory: returning, banner: nil, offersLocalSetup: true)
        == .servers)
    let failure = AuthBanner.error(SignInError(category: .transport, message: "offline"))
    #expect(
      OnboardingStep.initial(directory: ServerDirectory(), banner: failure, offersLocalSetup: true)
        == .servers)
    // A notice (for example after signing out) is not a failure.
    #expect(
      OnboardingStep.initial(
        directory: ServerDirectory(), banner: .notice("Signed out"), offersLocalSetup: true)
        == .landing)
  }

  @Test func withNothingToSetUpLocallyOnlyOrganizationServersShowTheLanding() {
    #expect(
      OnboardingStep.initial(
        directory: ServerDirectory(), banner: nil, offersLocalSetup: false) == .servers)
    #expect(
      OnboardingStep.initial(
        directory: ServerDirectory(managed: [managed(remote)]), banner: nil,
        offersLocalSetup: false) == .landing)
  }

  @Test func onlyNewUsersJoiningARemoteServerFromAHostCapableMacAreAskedWhereAgentsRun() {
    let empty = ServerDirectory()
    #expect(OnboardingStep.asksForRunner(joining: remote, directory: empty, localSetup: localSetup))
    #expect(
      !OnboardingStep.asksForRunner(joining: localInstall, directory: empty, localSetup: localSetup)
    )
    #expect(!OnboardingStep.asksForRunner(joining: remote, directory: empty, localSetup: nil))
    #expect(
      !OnboardingStep.asksForRunner(
        joining: remote, directory: ServerDirectory(recentServers: [remote]),
        localSetup: localSetup))
  }
}

struct LocalSetupTests {
  @Test func theLocalInstallIsThePlainHTTPLoopbackRootOnItsPort() {
    #expect(LocalInstall.isLocalInstall("http://127.0.0.1:6767"))
    #expect(LocalInstall.isLocalInstall("http://localhost:6767/"))
    #expect(!LocalInstall.isLocalInstall("http://127.0.0.1:8000"))
    #expect(!LocalInstall.isLocalInstall("https://127.0.0.1:6767"))
    #expect(!LocalInstall.isLocalInstall("http://127.0.0.1:6767/omnigent"))
    #expect(!LocalInstall.isLocalInstall(remote))
    #expect(LocalInstall.isLoopback("http://[::1]:9000"))
    #expect(!LocalInstall.isLoopback(remote))
  }

  @Test func theActionFollowsTheCLIAndServer() {
    #expect(!localSetup.needsCLI)
    #expect(LocalSetupState(cli: .missing("not found"), server: .stopped).needsCLI)
    // A running server needs no CLI lookup to open.
    let running = LocalSetupState(cli: .missing("x"), server: .running(url: localInstall))
    #expect(running.isRunning)
    #expect(!running.needsCLI)
  }
}

struct RecentStatusTests {
  @Test func checkingThenTheServersOwnName() {
    let checking = RecentStatus(url: remote, reachability: nil, isLastUsed: true)
    #expect(checking.title == "omnigent.example.com")
    #expect(checking.subtitle == "Checking\u{2026}")
    #expect(checking.badge == "Last used")
    let named = RecentStatus(url: remote, reachability: .omnigent(name: "Acme"), isLastUsed: false)
    #expect(named.title == "Acme (omnigent.example.com)")
    #expect(named.subtitle == "Omnigent server")
    #expect(named.badge == nil)
    #expect(named.systemImage == "server.rack")
  }

  @Test func anUnreachableRemoteIsAnErrorButAStoppedLocalInstallIsNot() {
    let remoteDown = RecentStatus(url: remote, reachability: .unreachable, isLastUsed: false)
    #expect(remoteDown.subtitle == "Can\u{2019}t reach")
    #expect(remoteDown.isError)
    let localDown = RecentStatus(url: localInstall, reachability: .unreachable, isLastUsed: false)
    #expect(localDown.title == "Local installation (127.0.0.1:6767)")
    #expect(localDown.subtitle == "Not running")
    #expect(!localDown.isError)
    #expect(localDown.systemImage == "laptopcomputer")
  }
}

struct AccountFormTests {
  @Test func usernamesAreTrimmedAndLowercased() {
    #expect(AccountFormInput.normalizedUsername("  Ada.L ") == "ada.l")
  }

  @Test func passwordsMustMatchAndBeLongEnough() {
    #expect(AccountFormInput.problem(password: "", confirmation: "") == nil)
    #expect(
      AccountFormInput.problem(password: "short", confirmation: "short")
        == "Password must be at least 8 characters.")
    #expect(
      AccountFormInput.problem(password: "longenough", confirmation: "longenougH")
        == "Passwords don\u{2019}t match.")
    #expect(AccountFormInput.problem(password: "longenough", confirmation: "longenough") == nil)
  }

  @Test func anInvitedAccountNeedsAnInvite() {
    func canSubmit(_ requiresInvite: Bool, _ invite: String?) -> Bool {
      AccountFormInput.canSubmit(
        username: "ada", password: "longenough", confirmation: "longenough",
        requiresInvite: requiresInvite, invite: invite)
    }
    #expect(canSubmit(false, nil))
    #expect(!canSubmit(true, nil))
    #expect(canSubmit(true, "token"))
    #expect(
      !AccountFormInput.canSubmit(
        username: " ", password: "longenough", confirmation: "longenough", requiresInvite: false,
        invite: nil))
  }

  @Test func thePreviewInviteParserReadsLinksAndTokens() {
    #expect(AuthActions.previewInviteToken("https://h.example.com/register?invite=abc") == "abc")
    #expect(AuthActions.previewInviteToken(" abc ") == "abc")
    #expect(AuthActions.previewInviteToken("https://h.example.com/register") == nil)
    #expect(AuthActions.previewInviteToken("") == nil)
  }
}

struct AccountScreenTests {
  private func required() -> SignInPhase {
    .signInRequired(
      baseUrl: remote, serverName: nil, mode: .accounts, methods: [.password], reason: nil)
  }

  @Test func theAccountFormPicksSignInOrCreation() {
    #expect(
      AuthViewState(phase: required()).screen
        == .password(
          server: ServerIdentity(baseUrl: remote, mode: .accounts), banner: nil,
          isSubmitting: false))
    for form in [AccountForm.createAdmin, .register] {
      let screen = AuthViewState(phase: required(), accountForm: form).screen
      #expect(
        screen
          == .createAccount(
            server: ServerIdentity(baseUrl: remote, mode: .accounts), form: form, banner: nil,
            isSubmitting: false))
    }
  }

  @Test func creatingKeepsTheCreationFormOnScreen() {
    let state = AuthViewState(
      phase: .signingIn(baseUrl: remote, method: .password), accountForm: .createAdmin)
    #expect(
      state.screen
        == .createAccount(
          server: ServerIdentity(baseUrl: remote), form: .createAdmin, banner: nil,
          isSubmitting: true))
    #expect(state.screen.isBusy)
  }
}

struct LandingFooterTests {
  @Test func linksMatchTheWebLandingInOrder() {
    #expect(LandingLink.all.map(\.id) == ["ios", "android", "github", "discord"])
    #expect(LandingLink.all.allSatisfy { $0.url.scheme == "https" })
  }
}
