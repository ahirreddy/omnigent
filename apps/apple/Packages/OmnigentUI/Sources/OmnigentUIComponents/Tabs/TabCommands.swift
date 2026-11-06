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
  /// Whether the window can split; the split items are hidden when it cannot (compact widths).
  public var supportsSplit = false
  /// Whether the window is split, for the toggle's title.
  public var isSplit = false
  /// Show or hide the split view (Command-\\).
  public var toggleSplit: (@MainActor () -> Void)?
  /// Focus a pane (Option-Command-Left and Right Arrow); `nil` when the window is not split.
  public var focusPane: (@MainActor (TabPane) -> Void)?
  /// Move the selected tab to the other pane, splitting the window when it is not.
  public var moveTabToOtherPane: (@MainActor () -> Void)?
  /// Start a shell in the selected session and show it (Option-Command-T).
  public var newShell: (@MainActor () -> Void)?

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

/// File > New Tab and Close Tab, a Tab menu (reopen, next and previous, Command-1 through 9,
/// pin, duplicate, move to a new window or the other pane, show all), and View > Split View with
/// pane focus. Add with `.commands { OmnigentTabCommands() }`.
///
/// Close Tab replaces File > Close (Command-W); without a tab it closes the window through
/// `closeWindow`, which is also File > Close Window (Shift-Command-W). A tab that cannot close (a
/// session's primary chat) disables Close Tab rather than closing the window.
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
        .keyboardShortcut(AppShortcuts.newTab)
        .disabled(actions == nil)
    }
    CommandGroup(replacing: .saveItem) {
      Button("Close Tab") {
        if let close = actions?.closeTab { close() } else { closeWindow?() }
      }
      .keyboardShortcut(AppShortcuts.closeTab)
      .disabled(actions?.closeTab == nil && (closeWindow == nil || (actions?.count ?? 0) > 0))
      if let closeWindow {
        Button("Close Window", action: closeWindow)
          .keyboardShortcut(AppShortcuts.closeWindow)
      }
    }
    CommandMenu("Tab") {
      Button("Reopen Closed Tab") { actions?.reopenClosedTab?() }
        .keyboardShortcut(AppShortcuts.reopenClosedTab)
        .disabled(actions?.reopenClosedTab == nil)
      Divider()
      Button("Show Next Tab") { actions?.selectNextTab?() }
        .keyboardShortcut(AppShortcuts.nextTab)
        .disabled(actions?.selectNextTab == nil)
      Button("Show Previous Tab") { actions?.selectPreviousTab?() }
        .keyboardShortcut(AppShortcuts.previousTab)
        .disabled(actions?.selectPreviousTab == nil)
      Button("Show All Tabs") { actions?.showAllTabs?() }
        .keyboardShortcut(AppShortcuts.showAllTabs)
        .disabled(actions?.showAllTabs == nil)
      Divider()
      ForEach(0..<9, id: \.self) { index in
        Button(index == 8 ? "Select Last Tab" : "Select Tab \(index + 1)") {
          actions?.selectTab(index)
        }
        .keyboardShortcut(AppShortcuts.selectTab(index))
        .disabled((actions?.count ?? 0) <= (index == 8 ? 0 : index))
      }
      Divider()
      Button("Show Terminal") { actions?.toggleTerminal?() }
        .keyboardShortcut(AppShortcuts.showTerminal)
        .disabled(actions?.toggleTerminal == nil)
      Button("New Shell") { actions?.newShell?() }
        .keyboardShortcut(AppShortcuts.newShell)
        .disabled(actions?.newShell == nil)
      Button("Pin or Unpin Tab") { actions?.togglePinned?() }
        .disabled(actions?.togglePinned == nil)
      Button("Duplicate Tab") { actions?.duplicateTab?() }
        .disabled(actions?.duplicateTab == nil)
      // A session's tabs stay together; another window shows a session, not a tab.
      if let move = actions?.moveTabToNewWindow {
        Button("Move Tab to New Window", action: move)
      }
      if actions?.supportsSplit == true {
        Button("Move Tab to Other Pane") { actions?.moveTabToOtherPane?() }
          .disabled(actions?.moveTabToOtherPane == nil)
      }
    }
    CommandGroup(after: .sidebar) {
      if actions?.supportsSplit == true {
        splitItems
      }
    }
  }

  @ViewBuilder private var splitItems: some View {
    Button(actions?.isSplit == true ? "Hide Split View" : "Show Split View") {
      actions?.toggleSplit?()
    }
    .keyboardShortcut(AppShortcuts.toggleSplit)
    .disabled(actions?.toggleSplit == nil)
    Button("Focus Left Pane") { actions?.focusPane?(.leading) }
      .keyboardShortcut(AppShortcuts.focusLeftPane)
      .disabled(actions?.focusPane == nil)
    Button("Focus Right Pane") { actions?.focusPane?(.trailing) }
      .keyboardShortcut(AppShortcuts.focusRightPane)
      .disabled(actions?.focusPane == nil)
  }
}
