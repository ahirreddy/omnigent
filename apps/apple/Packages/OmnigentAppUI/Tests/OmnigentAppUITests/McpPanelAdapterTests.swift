import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// The `/mcp` panel's rows in the web's words, with the button each one offers.
@Suite("Composer: /mcp panel rows")
struct McpPanelAdapterTests {
  private let settingsPage = URL(string: "https://omnigent.example.com/settings/mcp")

  private func row(
    account: McpAccount? = nil, signIn: McpSignIn? = nil, live: McpLiveState? = nil
  ) -> McpPanelRow {
    McpPanelRow(
      key: "host:docs", name: "docs", description: "kit plugin", account: account,
      signIn: signIn, live: live, liveName: live == nil ? nil : "plugin:kit:docs")
  }

  private func state(
    _ row: McpPanelRow, reconnecting: String? = nil,
    failure: McpPanelStore.ReconnectFailure? = nil, canReconnect: Bool = true
  ) -> McpServersPanelState.Row {
    ComposerAdapter.mcpRow(
      row, reconnecting: reconnecting, failure: failure, canReconnect: canReconnect,
      registrySignIn: settingsPage)
  }

  @Test func signingInComesBeforeReconnect() throws {
    let hostPage = try #require(URL(string: "https://sign.example.com/a"))
    let host = state(
      row(
        account: .signInRequired, signIn: .url(url: hostPage.absoluteString),
        live: McpLiveState(status: "needs-auth", error: nil)))
    #expect(host.symbol == .needsSignIn)
    #expect(host.account == "Account: Sign-in required")
    #expect(host.accountTone == .warning)
    #expect(host.live == "In this session: Needs sign-in")
    #expect(host.action == .signIn(hostPage))
    let registry = state(
      row(account: .signInRequired, signIn: .registry(serviceId: "search", typed: false)))
    #expect(registry.account == "Sign-in required", "no live state, no Account: prefix")
    #expect(registry.action == settingsPage.map { McpServersPanelState.Action.signIn($0) })
    let typed = state(
      row(account: .signInRequired, signIn: .registry(serviceId: "vault", typed: true)))
    #expect(typed.action == .signInFromSettings)
    #expect(state(row(account: .unavailable)).account == "Not available to your account")
  }

  @Test func aFailedLiveServerReconnectsAndSaysWhyItFailed() {
    let failed = row(account: .connected, live: McpLiveState(status: "failed", error: "exit 1"))
    let idle = state(failed)
    #expect(idle.symbol == .failed)
    #expect(idle.live == "In this session: Failed: exit 1")
    #expect(idle.liveTone == .failure)
    #expect(
      idle.action == .reconnect(name: "plugin:kit:docs", isReconnecting: false, isEnabled: true))
    let busy = state(failed, reconnecting: "other")
    #expect(
      busy.action == .reconnect(name: "plugin:kit:docs", isReconnecting: false, isEnabled: false))
    let refused = state(
      failed, failure: McpPanelStore.ReconnectFailure(name: "plugin:kit:docs", message: "denied"))
    #expect(refused.error == "Reconnect failed: denied")
    #expect(state(failed, canReconnect: false).action == nil, "read-only viewers only see it")
    let loaded = state(row(live: McpLiveState(status: "not-loaded", error: nil)))
    #expect(loaded.live == "In this session: Not loaded")
    #expect(loaded.symbol == .idle)
    #expect(state(row(account: .connected)).symbol == .connected)
  }
}
