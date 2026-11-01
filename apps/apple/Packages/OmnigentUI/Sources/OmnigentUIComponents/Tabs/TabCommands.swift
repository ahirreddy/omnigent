public import SwiftUI

/// What the key window's tabs can do from the menu bar and the keyboard. Published by the
/// window with `focusedSceneValue(\.tabCommands, ...)`; a `nil` action disables its item.
public struct TabCommandActions {
  /// New tab (Command-T).
  public var newTab: @MainActor () -> Void
  /// Close the selected tab (Command-W); `nil` when the window has no tab.
  public var closeTab: (@MainActor () -> Void)?
  /// Reopen the last closed tab (Shift-Command-T).
  public var reopenClosedTab: (@MainActor () -> Void)?
  /// Select the tab at a position, 0-based; 8 selects the last tab (Command-1 through 9).
  public var selectTab: @MainActor (Int) -> Void
  /// The next tab, wrapping (Control-Tab).
  public var selectNextTab: (@MainActor () -> Void)?
  /// The previous tab, wrapping (Control-Shift-Tab).
  public var selectPreviousTab: (@MainActor () -> Void)?
  /// Pin or unpin the selected tab.
  public var togglePinned: (@MainActor () -> Void)?
  /// Duplicate the selected tab.
  public var duplicateTab: (@MainActor () -> Void)?
  /// Move the selected tab to a new window.
  public var moveTabToNewWindow: (@MainActor () -> Void)?
  /// Show every tab in a list (Shift-Command-\\).
  public var showAllTabs: (@MainActor () -> Void)?
  /// Open a browser tab (Option-Command-B).
  public var openBrowser: (@MainActor () -> Void)?
  /// Show the selected session's terminal, or back to its chat (Control-`).
  public var toggleTerminal: (@MainActor () -> Void)?
  /// How many tabs are open, for enabling Command-1 through 9.
  public var count: Int

  /// Creates the actions.
  /// - Parameters:
  ///   - newTab: New tab.
  ///   - closeTab: Close tab.
  ///   - reopenClosedTab: Reopen closed tab.
  ///   - selectTab: Select by position.
  ///   - selectNextTab: Next tab.
  ///   - selectPreviousTab: Previous tab.
  ///   - togglePinned: Pin or unpin.
  ///   - duplicateTab: Duplicate.
  ///   - moveTabToNewWindow: Tear off.
  ///   - showAllTabs: The overview.
  ///   - openBrowser: Browser tab.
  ///   - toggleTerminal: Terminal and chat.
  ///   - count: Open tabs.
  public init(
    newTab: @escaping @MainActor () -> Void = {}, closeTab: (@MainActor () -> Void)? = nil,
    reopenClosedTab: (@MainActor () -> Void)? = nil,
    selectTab: @escaping @MainActor (Int) -> Void = { _ in },
    selectNextTab: (@MainActor () -> Void)? = nil,
    selectPreviousTab: (@MainActor () -> Void)? = nil,
    togglePinned: (@MainActor () -> Void)? = nil, duplicateTab: (@MainActor () -> Void)? = nil,
    moveTabToNewWindow: (@MainActor () -> Void)? = nil,
    showAllTabs: (@MainActor () -> Void)? = nil, openBrowser: (@MainActor () -> Void)? = nil,
    toggleTerminal: (@MainActor () -> Void)? = nil, count: Int = 0
  ) {
    self.newTab = newTab
    self.closeTab = closeTab
    self.reopenClosedTab = reopenClosedTab
    self.selectTab = selectTab
    self.selectNextTab = selectNextTab
    self.selectPreviousTab = selectPreviousTab
    self.togglePinned = togglePinned
    self.duplicateTab = duplicateTab
    self.moveTabToNewWindow = moveTabToNewWindow
    self.showAllTabs = showAllTabs
    self.openBrowser = openBrowser
    self.toggleTerminal = toggleTerminal
    self.count = count
  }
}

extension FocusedValues {
  /// The key window's tab commands.
  @Entry public var tabCommands: TabCommandActions?
}

/// File > New Tab and Close Tab, and a Tab menu (reopen, next and previous, Command-1 through 9,
/// pin, duplicate, move to a new window, show all). Add with `.commands { OmnigentTabCommands() }`.
///
/// Close Tab replaces File > Close (Command-W); without a tab it closes the window through
/// `closeWindow`, which is also File > Close Window (Shift-Command-W).
public struct OmnigentTabCommands: Commands {
  @FocusedValue(\.tabCommands) private var actions
  private let closeWindow: (@MainActor () -> Void)?

  /// Creates the commands.
  /// - Parameter closeWindow: Closes the key window (the Mac); `nil` where windows do not close.
  public init(closeWindow: (@MainActor () -> Void)? = nil) {
    self.closeWindow = closeWindow
  }

  /// The menus.
  public var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("New Tab") { actions?.newTab() }
        .keyboardShortcut("t", modifiers: .command)
        .disabled(actions == nil)
    }
    CommandGroup(replacing: .saveItem) {
      Button("Close Tab") {
        if let close = actions?.closeTab { close() } else { closeWindow?() }
      }
      .keyboardShortcut("w", modifiers: .command)
      .disabled(actions?.closeTab == nil && closeWindow == nil)
      if let closeWindow {
        Button("Close Window", action: closeWindow)
          .keyboardShortcut("w", modifiers: [.command, .shift])
      }
    }
    CommandMenu("Tab") {
      Button("Reopen Closed Tab") { actions?.reopenClosedTab?() }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(actions?.reopenClosedTab == nil)
      Divider()
      Button("Show Next Tab") { actions?.selectNextTab?() }
        .keyboardShortcut(.tab, modifiers: .control)
        .disabled(actions?.selectNextTab == nil)
      Button("Show Previous Tab") { actions?.selectPreviousTab?() }
        .keyboardShortcut(.tab, modifiers: [.control, .shift])
        .disabled(actions?.selectPreviousTab == nil)
      Button("Show All Tabs") { actions?.showAllTabs?() }
        .keyboardShortcut("\\", modifiers: [.command, .shift])
        .disabled(actions?.showAllTabs == nil)
      Divider()
      ForEach(0..<9, id: \.self) { index in
        Button(index == 8 ? "Select Last Tab" : "Select Tab \(index + 1)") {
          actions?.selectTab(index)
        }
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        .disabled((actions?.count ?? 0) <= (index == 8 ? 0 : index))
      }
      Divider()
      Button("Show Terminal") { actions?.toggleTerminal?() }
        .keyboardShortcut("`", modifiers: .control)
        .disabled(actions?.toggleTerminal == nil)
      Button("Pin or Unpin Tab") { actions?.togglePinned?() }
        .disabled(actions?.togglePinned == nil)
      Button("Duplicate Tab") { actions?.duplicateTab?() }
        .disabled(actions?.duplicateTab == nil)
      Button("Move Tab to New Window") { actions?.moveTabToNewWindow?() }
        .disabled(actions?.moveTabToNewWindow == nil)
    }
  }
}
