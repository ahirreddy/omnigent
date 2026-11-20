import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The `/mcp` panel (the web's `McpServerMenu`): the core's rows in the web's words, and its
/// buttons over ``McpPanelStore``.
extension ComposerAdapter {
  /// Live states a Reconnect can change, as in Claude Code's own `/mcp`.
  static let reconnectableMcpStatuses: Set<String> = ["failed", "needs-auth"]

  /// The panel for a started session; side chats have none, as on the web.
  /// - Parameters:
  ///   - store: The conversation.
  ///   - server: The connected server, whose MCP settings page signs in to a registry service.
  /// - Returns: The panel, or `nil`.
  static func mcpPanel(_ store: ConversationStore, server: ConnectedServer?)
    -> McpServersPanelState?
  {
    guard let header = store.header, header.settings?.isSideChat != true else { return nil }
    let mcp = store.composer.mcp
    guard let panel = mcp.panel else { return McpServersPanelState(isLoading: true) }
    var registrySignIn = server.flatMap { URL(string: $0.baseUrl) }
    registrySignIn?.append(path: "settings/mcp")
    let rows = panel.rows.map { row in
      mcpRow(
        row, reconnecting: mcp.reconnecting, failure: mcp.reconnectFailure,
        canReconnect: !isReadOnly(store), registrySignIn: registrySignIn)
    }
    // With live status unavailable no row carries the harness's name, so the panel says it.
    let failure = mcp.reconnectFailure.flatMap { failure in
      panel.rows.contains { $0.liveName == failure.name }
        ? nil : "Reconnecting \(failure.name) failed: \(failure.message)"
    }
    return McpServersPanelState(rows: rows, status: panel.status, failure: failure)
  }

  /// One row: its symbol, account and live lines, and its button.
  static func mcpRow(
    _ row: McpPanelRow, reconnecting: String?, failure: McpPanelStore.ReconnectFailure?,
    canReconnect: Bool, registrySignIn: URL?
  ) -> McpServersPanelState.Row {
    let live = row.live
    var state = McpServersPanelState.Row(
      id: row.key, name: row.name, detail: row.description, symbol: mcpSymbol(row))
    if let account = row.account {
      state.account = (live == nil ? "" : "Account: ") + mcpAccountLabel(account)
      state.accountTone = account == .signInRequired ? .warning : .secondary
    }
    if let live {
      state.live = "In this session: \(mcpLiveLabel(live))"
      state.liveTone =
        switch live.status {
        case "failed": .failure
        case "needs-auth": .warning
        default: .secondary
        }
    }
    let liveTrouble = live.map { reconnectableMcpStatuses.contains($0.status) } ?? false
    // Signing in comes first; the row offers Reconnect once the account is connected.
    if row.account == .signInRequired {
      state.action = mcpSignIn(row.signIn, registrySignIn: registrySignIn)
    } else if liveTrouble, canReconnect, let name = row.liveName {
      state.action = .reconnect(
        name: name, isReconnecting: reconnecting == name, isEnabled: reconnecting == nil)
    }
    // Once the row recovers, an old failure no longer describes it.
    if liveTrouble, let failure, failure.name == row.liveName {
      state.error = "Reconnect failed: \(failure.message)"
    }
    return state
  }

  /// The panel's reads and buttons.
  /// - Parameters:
  ///   - mcp: The panel's store.
  ///   - signIn: Opens a sign-in page in the browser.
  ///   - openSettings: Opens a server settings pane; `nil` hides the Settings links.
  ///   - openHarness: Opens the Harnesses pane on a host and harness.
  /// - Returns: The actions.
  static func mcpActions(
    _ mcp: McpPanelStore, signIn: @escaping @MainActor (URL) -> Void,
    openSettings: (@MainActor (ServerSettingsPane) -> Void)?,
    openHarness: (@MainActor (HarnessSettingsFocus) -> Void)? = nil
  ) -> McpServersPanelActions {
    var openHarnesses: (@MainActor () -> Void)?
    if let openHarness {
      // Go to Settings opens the session's harness on its host, as the web's link does.
      openHarnesses = {
        openHarness(
          HarnessSettingsFocus(
            harness: mcp.panel?.settingsHarness, hostID: mcp.panel?.settingsHostId))
      }
    } else if let openSettings {
      openHarnesses = { openSettings(.harnesses) }
    }
    return McpServersPanelActions(
      watch: { await mcp.watch() },
      perform: { action in
        switch action {
        case .signIn(let url): signIn(url)
        case .signInFromSettings: openSettings?(.mcp)
        case .reconnect(let name, _, _): Task { await mcp.reconnect(name) }
        }
      },
      openSettings: openHarnesses)
  }

  private static func mcpSignIn(_ signIn: McpSignIn?, registrySignIn: URL?)
    -> McpServersPanelState.Action?
  {
    switch signIn {
    case .url(let url): URL(string: url).map { .signIn($0) }
    case .registry(_, let typed): typed ? .signInFromSettings : registrySignIn.map { .signIn($0) }
    case nil: nil
    }
  }

  private static func mcpSymbol(_ row: McpPanelRow) -> McpServersPanelState.Symbol {
    switch row.live?.status {
    case "failed": return .failed
    case "pending": return .connecting
    case "needs-auth": return .needsSignIn
    default: break
    }
    if row.account == .signInRequired { return .needsSignIn }
    if row.account == .unavailable { return .unavailable }
    let connected = row.live.map { $0.status == "connected" } ?? (row.account == .connected)
    return connected ? .connected : .idle
  }

  private static func mcpAccountLabel(_ account: McpAccount) -> String {
    switch account {
    case .connected: "Connected"
    case .signInRequired: "Sign-in required"
    case .unavailable: "Not available to your account"
    }
  }

  private static func mcpLiveLabel(_ live: McpLiveState) -> String {
    let label =
      switch live.status {
      case "connected": "Connected"
      case "failed": "Failed"
      case "needs-auth": "Needs sign-in"
      case "pending": "Connecting\u{2026}"
      case "disabled": "Disabled"
      // The harness answered without this server: it is not loaded in the session.
      case "not-loaded": "Not loaded"
      default: live.status
      }
    guard live.status == "failed", let error = live.error else { return label }
    return "\(label): \(error)"
  }
}
