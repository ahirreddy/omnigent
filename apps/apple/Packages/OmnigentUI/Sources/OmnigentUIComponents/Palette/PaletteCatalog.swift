/// The palette's actions, the web's first and with its labels, then the native ones, with their
/// current-session availability.
enum PaletteCatalog {
  static func entries(state: PaletteViewState, commands: SessionCommandActions) -> [PaletteEntry] {
    var entries = [
      PaletteEntry(
        id: "new", title: "New chat", detail: state.scope, symbol: "square.and.pencil",
        shortcut: AppShortcuts.text(AppShortcuts.newSession),
        keywords: ["new session", "compose", "start"], target: .newSession),
      PaletteEntry(
        id: "inbox", title: "Go to Inbox", detail: state.scope, symbol: "tray",
        keywords: ["notifications", "comments", "needs you"], target: .inbox),
      PaletteEntry(
        id: "settings", title: "Go to Settings", detail: "Preferences and servers",
        symbol: "gearshape", shortcut: AppShortcuts.text(AppShortcuts.settings),
        keywords: ["preferences", "configuration", "account"], target: .settings),
      PaletteEntry(
        id: "sidebar", title: "Toggle conversations sidebar", detail: "Window",
        symbol: "sidebar.left", shortcut: AppShortcuts.text(AppShortcuts.toggleSidebarAlias),
        keywords: ["sessions list", "left panel"], target: .toggleSidebar),
      PaletteEntry(
        id: "inspector", title: "Toggle workspace sidebar", detail: "Current session",
        symbol: "sidebar.right", shortcut: AppShortcuts.text(AppShortcuts.toggleInspector),
        isEnabled: commands.toggleInspector != nil,
        keywords: ["right panel", "files", "changes"], target: .toggleInspector),
      PaletteEntry(
        id: "find", title: "Find a session by name", detail: state.scope,
        symbol: "magnifyingglass", shortcut: AppShortcuts.text(AppShortcuts.findSession),
        target: .findSession),
      PaletteEntry(
        id: "next", title: "Go to next session that needs you", detail: state.scope,
        symbol: "hand.raised", isEnabled: state.hasNextRequest,
        keywords: ["request", "approval"], target: .nextRequest),
      PaletteEntry(
        id: "changes", title: "Open Changes", detail: "Current session",
        symbol: "doc.text.magnifyingglass", isEnabled: commands.openChanges != nil,
        keywords: ["diff"], target: .changes),
      PaletteEntry(
        id: "composer", title: "Focus chat input", detail: "Current session",
        symbol: "text.cursor", shortcut: AppShortcuts.text(AppShortcuts.focusComposer),
        isEnabled: commands.focusComposer != nil, keywords: ["composer"], target: .composer),
      PaletteEntry(
        id: "terminal", title: "Toggle Chat / Terminal view", detail: "Current session",
        symbol: "apple.terminal", shortcut: AppShortcuts.text(AppShortcuts.toggleViewMode),
        isEnabled: commands.toggleViewMode != nil, target: .toggleTerminal),
      PaletteEntry(
        id: "server", title: "Switch server", detail: "Configured servers", symbol: "server.rack",
        target: .switchServer),
    ]
    // The pages the server offers, after Go to Inbox as in the sidebar.
    let inbox = (entries.firstIndex { $0.id == "inbox" } ?? entries.count - 1) + 1
    entries.insert(contentsOf: pages(state), at: inbox)
    return entries
  }

  /// Automations and Usage, when the server offers them.
  private static func pages(_ state: PaletteViewState) -> [PaletteEntry] {
    var pages: [PaletteEntry] = []
    if state.showsAutomations {
      pages.append(
        PaletteEntry(
          id: "automations", title: "Go to Automations", detail: state.scope, symbol: "clock",
          keywords: ["scheduled", "recurring", "cron"], target: .automations))
    }
    if state.showsUsage {
      pages.append(
        PaletteEntry(
          id: "usage", title: "Go to Usage", detail: state.scope, symbol: "creditcard",
          target: .usage))
    }
    return pages
  }
}
