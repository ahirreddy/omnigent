/// The initial command catalog and its current-session availability.
enum PaletteCatalog {
  static func entries(state: PaletteViewState, commands: SessionCommandActions) -> [PaletteEntry] {
    [
      PaletteEntry(
        id: "find", title: "Find session", detail: state.scope, symbol: "magnifyingglass",
        target: .findSession),
      PaletteEntry(
        id: "new", title: "New session", detail: state.scope, symbol: "plus.bubble", shortcut: "⌘N",
        target: .newSession),
      PaletteEntry(
        id: "next", title: "Next request needing response", detail: state.scope,
        symbol: "hand.raised", isEnabled: state.hasNextRequest, target: .nextRequest),
      PaletteEntry(
        id: "changes", title: "Open Changes", detail: "Current session",
        symbol: "doc.text.magnifyingglass", isEnabled: commands.openChanges != nil,
        target: .changes),
      PaletteEntry(
        id: "server", title: "Switch server", detail: "Configured servers", symbol: "server.rack",
        target: .switchServer),
      PaletteEntry(
        id: "composer", title: "Focus composer", detail: "Current session", symbol: "text.cursor",
        shortcut: "⌃⇧L", isEnabled: commands.focusComposer != nil, target: .composer),
      PaletteEntry(
        id: "terminal", title: "Toggle Chat/Terminal", detail: "Current session",
        symbol: "apple.terminal", shortcut: "⌥⌘\\",
        isEnabled: commands.toggleViewMode != nil, target: .toggleTerminal),
      PaletteEntry(
        id: "inbox", title: "Open Inbox", detail: state.scope, symbol: "tray", target: .inbox),
    ]
  }
}
