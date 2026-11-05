import SwiftUI

/// One line of the Keyboard Shortcuts sheet.
nonisolated public struct ShortcutRow: Hashable, Sendable, Identifiable {
  /// What the keys do.
  public var title: String
  /// The keys, as the menu bar writes them.
  public var keys: String

  /// The title, unique within a group.
  public var id: String { title }

  /// Creates a row.
  /// - Parameters:
  ///   - title: What the keys do.
  ///   - keys: The keys.
  public init(_ title: String, _ keys: String) {
    self.title = title
    self.keys = keys
  }
}

/// A titled section of the Keyboard Shortcuts sheet.
nonisolated public struct ShortcutGroup: Hashable, Sendable, Identifiable {
  /// The section title.
  public var title: String
  /// When the shortcuts apply, shown after the title.
  public var note: String?
  /// The rows.
  public var rows: [ShortcutRow]

  /// The title.
  public var id: String { title }
}

/// The Keyboard Shortcuts sheet's content, grouped as the web's dialog is and built from
/// ``AppShortcuts``.
enum ShortcutGuide {
  /// The groups for a platform and send preference.
  /// - Parameters:
  ///   - submitWithCommandReturn: Return inserts a newline and Command-Return sends.
  ///   - isMac: The Mac, with its menu-bar-only shortcuts.
  /// - Returns: The sheet's sections.
  static func groups(submitWithCommandReturn: Bool, isMac: Bool) -> [ShortcutGroup] {
    [
      general,
      chats(submitWithCommandReturn: submitWithCommandReturn || !isMac),
      ShortcutGroup(
        title: "Navigation",
        rows: [
          row("Previous session", AppShortcuts.previousSession),
          row("Next session", AppShortcuts.nextSession),
        ]),
      view(isMac: isMac),
      tabs,
      panes(isMac: isMac),
      ShortcutGroup(
        title: "Inbox", note: "when the list has focus",
        rows: [
          ShortcutRow("Next / previous item", "J / K or ↓ / ↑"),
          ShortcutRow("Open session", "Return"),
          ShortcutRow("Approve / mark read", "E"),
          ShortcutRow("Search", "/"),
        ]),
      ShortcutGroup(
        title: "Command palette",
        rows: [
          ShortcutRow("Navigate results", "↓ / ↑"),
          ShortcutRow("Open selected result", "Return"),
          ShortcutRow("Close", "Esc"),
        ]),
    ] + (isMac ? [windows] : [])
  }

  private static var general: ShortcutGroup {
    ShortcutGroup(
      title: "General",
      rows: [
        row("Start a new session", AppShortcuts.newSession),
        row("Open command palette", AppShortcuts.commandPalette),
        row("Find a session by name", AppShortcuts.findSession),
        row("Rename current session", AppShortcuts.renameSession),
        row("Open Settings", AppShortcuts.settings),
        row("Show keyboard shortcuts", AppShortcuts.keyboardShortcuts),
      ])
  }

  /// Return sends unless the preference (or a touch keyboard) moves sending to Command-Return.
  private static func chats(submitWithCommandReturn: Bool) -> ShortcutGroup {
    let send = submitWithCommandReturn ? AppShortcuts.text(AppShortcuts.send) : "Return"
    let newline = submitWithCommandReturn ? "Return" : "⇧Return or ⌥Return"
    return ShortcutGroup(
      title: "In chats",
      rows: [
        ShortcutRow("Send message", send),
        row("Send now or queue, while the agent works", AppShortcuts.sendAlternative),
        ShortcutRow("New line in message", newline),
        row("Approve the pending request", AppShortcuts.send),
        row("Open model picker", AppShortcuts.chooseModel),
        row("Cycle model", AppShortcuts.cycleModel),
        row("Cycle reasoning effort", AppShortcuts.cycleEffort),
        ShortcutRow("Cycle approval mode", "⇧Tab"),
        row("Focus chat input", AppShortcuts.focusComposer),
        row("Toggle voice dictation", AppShortcuts.dictate),
        row("Expand or collapse the editor", AppShortcuts.expandEditor),
        ShortcutRow("Stop response", "Esc or \(AppShortcuts.text(AppShortcuts.stopAgent))"),
        row("Jump to latest", AppShortcuts.jumpToLatest),
        row("Previous / next message", AppShortcuts.previousMessage, AppShortcuts.nextMessage),
      ])
  }

  private static func view(isMac: Bool) -> ShortcutGroup {
    var rows = [
      row("Toggle Chat / Terminal view", AppShortcuts.toggleViewMode),
      row("Toggle right panel", AppShortcuts.toggleInspector, AppShortcuts.rightPanel, or: true),
      row("Search workspace contents", AppShortcuts.searchWorkspace),
      ShortcutRow(
        "Select a right panel tab",
        "\(AppShortcuts.text(AppShortcuts.rightPanelTab(0)))–\(InspectorTab.allCases.count)"),
      row("Open a new shell", AppShortcuts.newShell),
    ]
    if isMac {
      rows.insert(
        row(
          "Toggle sessions sidebar", AppShortcuts.toggleSidebarAlias, AppShortcuts.toggleSidebar,
          or: true),
        at: 1)
      rows.append(row("Open a new browser tab", AppShortcuts.openBrowser))
    }
    return ShortcutGroup(title: "View", rows: rows)
  }

  private static var tabs: ShortcutGroup {
    ShortcutGroup(
      title: "Tabs",
      rows: [
        row("New tab", AppShortcuts.newTab),
        row("Close tab", AppShortcuts.closeTab),
        row("Reopen closed tab", AppShortcuts.reopenClosedTab),
        ShortcutRow(
          "Select tab 1–8 / last tab",
          "\(AppShortcuts.text(AppShortcuts.selectTab(0)))–8 / "
            + AppShortcuts.text(AppShortcuts.selectTab(8))),
        row("Next / previous tab", AppShortcuts.nextTab, AppShortcuts.previousTab),
        row("Show all tabs", AppShortcuts.showAllTabs),
        row("Session terminal / chat", AppShortcuts.showTerminal),
      ])
  }

  private static func panes(isMac: Bool) -> ShortcutGroup {
    let arrows = keys(AppShortcuts.focusLeftPane, AppShortcuts.focusRightPane)
    let brackets = keys(AppShortcuts.previousPane, AppShortcuts.nextPane)
    return ShortcutGroup(
      title: "Panes", note: "in split view",
      rows: [
        row("Show or hide split view", AppShortcuts.toggleSplit),
        ShortcutRow("Focus left / right pane", isMac ? "\(arrows) or \(brackets)" : arrows),
      ])
  }

  private static var windows: ShortcutGroup {
    ShortcutGroup(
      title: "Windows and search",
      rows: [
        row("New window", AppShortcuts.newWindow),
        row("Close window", AppShortcuts.closeWindow),
        row("Reconnect", AppShortcuts.reconnect),
        ShortcutRow("Zoom in / out / actual size", "⌘+ / ⌘− / ⌘0"),
        row("Find", AppShortcuts.find),
        row("Find next / previous", AppShortcuts.findNext, AppShortcuts.findPrevious),
        row("Use selection for Find", AppShortcuts.useSelectionForFind),
        row("Undo sidebar action", AppShortcuts.undo),
      ])
  }

  private static func row(
    _ title: String, _ first: KeyboardShortcut, _ second: KeyboardShortcut? = nil,
    or alternative: Bool = false
  ) -> ShortcutRow {
    guard let second else { return ShortcutRow(title, AppShortcuts.text(first)) }
    return ShortcutRow(
      title,
      alternative
        ? "\(AppShortcuts.text(first)) or \(AppShortcuts.text(second))"
        : keys(first, second))
  }

  private static func keys(_ first: KeyboardShortcut, _ second: KeyboardShortcut) -> String {
    "\(AppShortcuts.text(first)) / \(AppShortcuts.text(second))"
  }
}
