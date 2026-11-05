import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// The harness details page and fix sheet mapping (web SettingsHarnessesSection.test.tsx).
struct HarnessFixAdapterTests {
  private func detail(
    harness: String = "codex-native", availability: HarnessAvailability = .ready,
    accounts: [HarnessAccountEntry] = [], loginSupported: Bool = true,
    sandbox: String? = nil
  ) throws -> HarnessDetail {
    let catalog = HarnessSetupCatalog(
      harnessInstall: true, installableHarnesses: ["codex-native"], harnesses: [],
      hosts: [
        SetupHost(
          hostId: "h1", name: "Mac", status: "online", sandboxProvider: sandbox,
          harnesses: [HarnessAvailabilityEntry(harness: harness, availability: availability)],
          accounts: accounts.isEmpty ? nil : accounts, gatewayInference: nil,
          loginSupported: loginSupported)
      ])
    return try #require(
      harnessDetail(catalog: catalog, harness: harness, name: "Codex", hostId: "h1"))
  }

  private func account(_ kind: String, email: String) -> HarnessAccountEntry {
    HarnessAccountEntry(
      key: "codex",
      account: HarnessAccount(
        kind: kind, email: email, org: nil, plan: nil, providers: [], expired: false,
        identity: email))
  }

  @Test func readySubscriptionOffersSwitchAccount() throws {
    let detail = try detail(accounts: [account("chatgpt", email: "a@b.co")])
    let state = HarnessFixAdapter.detail(detail, startup: nil, notice: nil)
    #expect(state.status == "Configured \u{b7} a@b.co")
    #expect(state.credentialAction == "Switch Account")
    #expect(state.startup == .loading)
    #expect(HarnessFixAdapter.mode(for: .switchAccount, detail: detail) == .switch)
  }

  @Test func outdatedHarnessWarnsWithUpdateUnlessSandboxed() throws {
    let outdated = try detail(availability: .versionTooLow)
    let state = HarnessFixAdapter.detail(outdated, startup: nil, notice: nil)
    #expect(state.warning?.action == "Update")
    let sandboxed = try detail(availability: .versionTooLow, sandbox: "modal")
    #expect(HarnessFixAdapter.detail(sandboxed, startup: nil, notice: nil).warning?.action == nil)
  }

  @Test func startupSectionCoversEveryRead() {
    let startup = HarnessStartup(
      command: "/bin/codex", found: true, source: "Default command on Mac.", args: nil,
      argCount: 2, environment: [HarnessStartupVariable(name: "A", value: "")],
      inheritsEnvironment: false, unset: ["X", "Y"], hostOutdated: false)
    guard
      case .loaded(let state) = HarnessFixAdapter.startupSection(
        .loaded(.loaded(startup: startup)), hostName: "Mac")
    else {
      Issue.record("expected the startup command")
      return
    }
    #expect(
      state.environmentNote
        == "Inherited environment cleared. Removed before applying overrides: X, Y.")
    #expect(state.argumentsNote == "2 configured arguments. Update Mac to view values.")
    #expect(HarnessFixAdapter.startupSection(.loaded(.notReported), hostName: "Mac") == .hidden)
    #expect(
      HarnessFixAdapter.startupSection(.loaded(.hostOutdated), hostName: "Mac")
        == .unavailable("Update Mac to see launch settings."))
  }

  @Test func sheetTitlesAndPhasesFollowTheWeb() throws {
    let detail = try detail(accounts: [account("chatgpt", email: "a@b.co")])
    let confirm = HarnessFixAdapter.sheet(
      .confirmSwitch(account: "a@b.co"), mode: .switch, detail: detail, isChecking: false)
    #expect(confirm?.title == "Switch Codex Account?")
    #expect(confirm?.phase == .confirmSwitch(account: "a@b.co", asksForEmail: false))
    let login = HarnessLoginStart(
      loginId: "l1", verificationUrl: "https://auth.openai.com/device", userCode: "AB",
      expiresAt: 10)
    let code = HarnessFixAdapter.sheet(
      .deviceCode(login), mode: .switch, detail: detail, isChecking: false)
    #expect(code?.title == "Sign In to Codex on Mac")
    #expect(
      code?.phase
        == .deviceCode(
          link: URL(string: "https://auth.openai.com/device"), code: "AB",
          expiresAt: Date(timeIntervalSince1970: 10)))
    #expect(HarnessFixAdapter.secureLink("http://x.io") == nil)
    let failed = HarnessFixAdapter.sheet(
      .failed("boom"), mode: .update, detail: detail, isChecking: false)
    #expect(failed?.title == "Couldn\u{2019}t Update Codex")
    #expect(HarnessFixAdapter.sheet(.idle, mode: .update, detail: detail, isChecking: false) == nil)
  }
}
