public import SwiftUI

/// The app's key equivalents, defined once for the menus, the buttons that bind them and the
/// Keyboard Shortcuts sheet, so the sheet shows what the keys actually do.
///
/// Shortcuts bound outside this package (the desktop menus) or by key handlers rather than
/// buttons are listed here too, so the sheet and the duplicate check cover them.
public enum AppShortcuts {
  // MARK: Navigate

  /// Command palette.
  public static let commandPalette = KeyboardShortcut("k", modifiers: .command)
  /// The palette scoped to sessions, searching by name.
  public static let findSession = KeyboardShortcut("s", modifiers: [.command, .option])
  /// This sheet.
  public static let keyboardShortcuts = KeyboardShortcut("/", modifiers: .command)
  /// The previous session in the sidebar.
  public static let previousSession = KeyboardShortcut("[", modifiers: .command)
  /// The next session in the sidebar.
  public static let nextSession = KeyboardShortcut("]", modifiers: .command)

  /// The pinned session at a position, 0-based; 9 is the tenth (the 0 key). Command-digit selects
  /// tabs, so pins take Control-Command-digit (the web's browser build moves them off it too).
  /// - Parameter index: The position, 0 to 9.
  /// - Returns: Control-Command and the digit.
  public static func pinnedSession(_ index: Int) -> KeyboardShortcut {
    KeyboardShortcut(
      KeyEquivalent(Character("\((index + 1) % 10)")), modifiers: [.command, .control])
  }

  // MARK: Conversation

  /// Send while Return inserts a newline, or the Send button's equivalent.
  public static let send = KeyboardShortcut(.return, modifiers: .command)
  /// The send button's alternative while the agent works (send now, or queue).
  public static let sendAlternative = KeyboardShortcut(.return, modifiers: [.command, .option])
  /// Stop the running turn.
  public static let stopAgent = KeyboardShortcut(".", modifiers: .command)
  /// Rename the session.
  public static let renameSession = KeyboardShortcut("r", modifiers: [.command, .option])
  /// Focus the composer.
  public static let focusComposer = KeyboardShortcut("l", modifiers: [.control, .shift])
  /// Scroll to the newest message.
  public static let jumpToLatest = KeyboardShortcut(.downArrow, modifiers: .command)
  /// The previous message of yours in the transcript.
  public static let previousMessage = KeyboardShortcut(.upArrow, modifiers: [.command, .option])
  /// The next message of yours in the transcript.
  public static let nextMessage = KeyboardShortcut(.downArrow, modifiers: [.command, .option])
  /// Dictation into the composer.
  public static let dictate = KeyboardShortcut("v", modifiers: [.command, .option])
  /// Expand or collapse the composer's editor.
  public static let expandEditor = KeyboardShortcut("e", modifiers: [.command, .shift])
  /// The model picker.
  public static let chooseModel = KeyboardShortcut("m", modifiers: [.control, .shift])
  /// The next model.
  public static let cycleModel = KeyboardShortcut("m", modifiers: [.control, .option])
  /// The next reasoning effort.
  public static let cycleEffort = KeyboardShortcut("e", modifiers: [.control, .option])

  // MARK: View

  /// Chat and the harness terminal.
  public static let toggleViewMode = KeyboardShortcut("\\", modifiers: [.command, .option])
  /// The right panel, from the menu bar.
  public static let toggleInspector = KeyboardShortcut("i", modifiers: [.command, .option])
  /// The right panel, from the session header (the web's workspace sidebar key).
  public static let rightPanel = KeyboardShortcut("]", modifiers: [.command, .option])
  /// The sessions sidebar: the system's View > Show Sidebar.
  public static let toggleSidebar = KeyboardShortcut("s", modifiers: [.command, .control])
  /// The sessions sidebar, with the web's key.
  public static let toggleSidebarAlias = KeyboardShortcut("[", modifiers: [.command, .option])
  /// The right panel's content search.
  public static let searchWorkspace = KeyboardShortcut("f", modifiers: [.command, .shift])

  /// The right panel's tab at a position, 0-based.
  /// - Parameter index: The position.
  /// - Returns: Option-Command and the 1-based digit.
  public static func rightPanelTab(_ index: Int) -> KeyboardShortcut {
    KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
  }

  // MARK: Tabs

  /// New tab.
  public static let newTab = KeyboardShortcut("t", modifiers: .command)
  /// Close the selected tab.
  public static let closeTab = KeyboardShortcut("w", modifiers: .command)
  /// Reopen the last closed tab.
  public static let reopenClosedTab = KeyboardShortcut("t", modifiers: [.command, .shift])
  /// The next tab.
  public static let nextTab = KeyboardShortcut(.tab, modifiers: .control)
  /// The previous tab.
  public static let previousTab = KeyboardShortcut(.tab, modifiers: [.control, .shift])
  /// Every tab in a list.
  public static let showAllTabs = KeyboardShortcut("\\", modifiers: [.command, .shift])
  /// A session's terminal, or back to its chat.
  public static let showTerminal = KeyboardShortcut("`", modifiers: .control)
  /// A new shell in the selected session.
  public static let newShell = KeyboardShortcut("t", modifiers: [.command, .option])
  /// A browser tab.
  public static let openBrowser = KeyboardShortcut("b", modifiers: [.command, .option])
  /// Show or hide the split view.
  public static let toggleSplit = KeyboardShortcut("\\", modifiers: .command)
  /// Focus the left pane.
  public static let focusLeftPane = KeyboardShortcut(.leftArrow, modifiers: [.command, .option])
  /// Focus the right pane.
  public static let focusRightPane = KeyboardShortcut(
    .rightArrow, modifiers: [.command, .option])
  /// Focus the previous pane, with the web's key.
  public static let previousPane = KeyboardShortcut("[", modifiers: [.command, .option, .shift])
  /// Focus the next pane, with the web's key.
  public static let nextPane = KeyboardShortcut("]", modifiers: [.command, .option, .shift])

  /// The tab at a position, 0-based; 8 is the last tab.
  /// - Parameter index: The position.
  /// - Returns: Command and the 1-based digit.
  public static func selectTab(_ index: Int) -> KeyboardShortcut {
    KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
  }

  // MARK: Window (bound by the desktop menus)

  /// New session.
  public static let newSession = KeyboardShortcut("n", modifiers: .command)
  /// New window.
  public static let newWindow = KeyboardShortcut("n", modifiers: [.command, .shift])
  /// Close window.
  public static let closeWindow = KeyboardShortcut("w", modifiers: [.command, .shift])
  /// Settings.
  public static let settings = KeyboardShortcut(",", modifiers: .command)
  /// Reconnect the window's server.
  public static let reconnect = KeyboardShortcut("r", modifiers: [.command, .option, .shift])
  /// Find.
  public static let find = KeyboardShortcut("f", modifiers: .command)
  /// Find next.
  public static let findNext = KeyboardShortcut("g", modifiers: .command)
  /// Find previous.
  public static let findPrevious = KeyboardShortcut("g", modifiers: [.command, .shift])
  /// Use the selection for Find.
  public static let useSelectionForFind = KeyboardShortcut("e", modifiers: .command)
  /// Undo the last sidebar action.
  public static let undo = KeyboardShortcut("z", modifiers: .command)

  // MARK: Text

  /// How a shortcut reads in the menu bar: modifiers in the system order, then the key.
  /// - Parameter shortcut: The shortcut.
  /// - Returns: For example "⌥⌘R" or "⌃Tab".
  public static func text(_ shortcut: KeyboardShortcut) -> String {
    let modifiers = shortcut.modifiers
    var text = ""
    if modifiers.contains(.control) { text += "⌃" }
    if modifiers.contains(.option) { text += "⌥" }
    if modifiers.contains(.shift) { text += "⇧" }
    if modifiers.contains(.command) { text += "⌘" }
    return text + keyName(shortcut.key)
  }

  /// The key's name or glyph.
  /// - Parameter key: The key.
  /// - Returns: For example "Return", "↑" or "K".
  public static func keyName(_ key: KeyEquivalent) -> String {
    switch key {
    case .return: "Return"
    case .tab: "Tab"
    case .escape: "Esc"
    case .space: "Space"
    case .delete: "Delete"
    case .upArrow: "↑"
    case .downArrow: "↓"
    case .leftArrow: "←"
    case .rightArrow: "→"
    default: String(key.character).uppercased()
    }
  }
}
