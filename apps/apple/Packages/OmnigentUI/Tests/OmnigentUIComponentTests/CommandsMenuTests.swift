#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// What the menus asked for.
  @MainActor
  private final class MenuLog {
    var calls: [String] = []

    func log(_ name: String) -> @MainActor () -> Void {
      { [self] in calls.append(name) }
    }
  }

  /// A menu item's title, shortcut and what it runs.
  private struct MenuItemCheck {
    let title: String
    let shortcut: KeyboardShortcut?
    let call: String

    init(_ title: String, _ shortcut: KeyboardShortcut?, _ call: String) {
      self.title = title
      self.shortcut = shortcut
      self.call = call
    }
  }

  /// Items in a real `Menu`, so AppKit builds the same menu items the menu bar shows.
  @MainActor
  private func window(_ items: some View) -> OffscreenWindow<AnyView> {
    OffscreenWindow(
      AnyView(Menu("Items") { items }.frame(width: 200, height: 40)), width: 200, height: 40)
  }

  extension OffscreenWindow {
    /// The menu's items.
    fileprivate var items: NSMenu {
      get throws { try openMenu(control: 0) }
    }

    /// Checks an item's shortcut, then runs it and checks what it did.
    fileprivate func expect(
      _ title: String, _ shortcut: KeyboardShortcut?, runs call: String, log: MenuLog
    ) throws {
      let item = try #require(try items.item(named: title), "\(title)")
      #expect(item.isEnabled, "\(title)")
      var modifiers: NSEvent.ModifierFlags = []
      if let shortcut {
        if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
        if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
        if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
      }
      let key = shortcut.map { String($0.key.character) } ?? ""
      #expect(item.keyEquivalent.lowercased() == key.lowercased(), "\(title)")
      #expect(item.keyEquivalentModifierMask == modifiers, "\(title)")
      log.calls = []
      try choose(title, in: try items)
      #expect(log.calls == [call], "\(title)")
    }
  }

  @Suite("Commands: the Conversation and Navigate menus", .serialized)
  @MainActor
  struct CommandsSessionMenuTests {
    private func allActions(_ log: MenuLog) -> SessionCommandActions {
      var actions = SessionCommandActions(
        send: log.log("send"), interrupt: log.log("stop"), jumpToLatest: log.log("latest"),
        focusComposer: log.log("composer"), toggleInspector: log.log("inspector"),
        previousSession: log.log("previous"), nextSession: log.log("next"),
        toggleViewMode: log.log("view mode"), openChanges: log.log("changes"))
      actions.rename = log.log("rename")
      actions.chooseModel = log.log("choose model")
      actions.cycleModel = log.log("next model")
      actions.cycleEffort = log.log("next effort")
      return actions
    }

    @Test("Each item has its shortcut and runs its action")
    func items() throws {
      let log = MenuLog()
      let screen = window(ConversationMenuItems(actions: allActions(log)))
      defer { screen.close() }
      let table: [MenuItemCheck] = [
        .init("Send Message", AppShortcuts.send, "send"),
        .init("Stop Agent", AppShortcuts.stopAgent, "stop"),
        .init("Rename Session\u{2026}", AppShortcuts.renameSession, "rename"),
        .init("Focus Composer", AppShortcuts.focusComposer, "composer"),
        .init("Jump to Latest", AppShortcuts.jumpToLatest, "latest"),
        .init("Choose Model\u{2026}", AppShortcuts.chooseModel, "choose model"),
        .init("Next Model", AppShortcuts.cycleModel, "next model"),
        .init("Next Reasoning Effort", AppShortcuts.cycleEffort, "next effort"),
        .init("Toggle Chat and Terminal", AppShortcuts.toggleViewMode, "view mode"),
        .init("Toggle Right Panel", AppShortcuts.toggleInspector, "inspector"),
        .init("Previous Session", AppShortcuts.previousSession, "previous"),
        .init("Next Session", AppShortcuts.nextSession, "next"),
      ]
      for check in table {
        try screen.expect(check.title, check.shortcut, runs: check.call, log: log)
      }
    }

    @Test("Without a session every item is disabled")
    func noSession() throws {
      for actions in [SessionCommandActions(), nil] {
        let screen = window(ConversationMenuItems(actions: actions))
        defer { screen.close() }
        let enabled = try screen.items.items.filter { !$0.isSeparatorItem && $0.isEnabled }
        #expect(enabled.isEmpty)
        #expect(try screen.items.titles.count == 12)
      }
    }

    @Test("While an approval owns Command-Return, Send gives up the shortcut but not the item")
    func approvalOwnsReturn() throws {
      let log = MenuLog()
      var actions = allActions(log)
      actions.approveOwnsCommandReturn = true
      let screen = window(ConversationMenuItems(actions: actions))
      defer { screen.close() }
      try screen.expect("Send Message", nil, runs: "send", log: log)
    }

    @Test("Navigate opens the palette, find and the shortcut guide")
    func navigate() throws {
      let log = MenuLog()
      let palette = PaletteCommandActions(
        openPalette: log.log("palette"), openShortcuts: log.log("shortcuts"),
        findSession: log.log("find"))
      let screen = window(NavigateMenuItems(palette: palette))
      defer { screen.close() }
      try screen.expect(
        "Command Palette\u{2026}", AppShortcuts.commandPalette, runs: "palette", log: log)
      try screen.expect(
        "Find Session by Name\u{2026}", AppShortcuts.findSession, runs: "find", log: log)
      try screen.expect(
        "Keyboard Shortcuts\u{2026}", AppShortcuts.keyboardShortcuts, runs: "shortcuts", log: log)
    }

    @Test("Navigate is disabled without a window")
    func navigateDisabled() throws {
      let screen = window(NavigateMenuItems(palette: nil))
      defer { screen.close() }
      let enabled = try screen.items.items.filter(\.isEnabled)
      #expect(enabled.isEmpty)
    }
  }

  @Suite("Commands: the File, View and Server menus", .serialized)
  @MainActor
  struct CommandsServerMenuTests {
    private func allActions(_ log: MenuLog) -> ServerCommandActions {
      var actions = ServerCommandActions(
        reconnect: log.log("reconnect"), changeServer: log.log("change"),
        signOut: log.log("sign out"))
      actions.newSession = log.log("new session")
      actions.newWindow = log.log("new window")
      return actions
    }

    @Test("New Session and New Window")
    func file() throws {
      let log = MenuLog()
      let screen = window(ServerFileMenuItems(actions: allActions(log)))
      defer { screen.close() }
      try screen.expect("New Session", AppShortcuts.newSession, runs: "new session", log: log)
      try screen.expect("New Window", AppShortcuts.newWindow, runs: "new window", log: log)
    }

    @Test("Reconnect")
    func reconnect() throws {
      let log = MenuLog()
      let screen = window(ReconnectMenuItem(actions: allActions(log)))
      defer { screen.close() }
      try screen.expect("Reconnect", AppShortcuts.reconnect, runs: "reconnect", log: log)
    }

    @Test("Change Server and Sign Out")
    func server() throws {
      let log = MenuLog()
      let screen = window(ServerMenuItems(actions: allActions(log)))
      defer { screen.close() }
      try screen.expect("Change Server\u{2026}", nil, runs: "change", log: log)
      try screen.expect("Sign Out of Server", nil, runs: "sign out", log: log)
    }

    @Test("Settings opens the settings screen")
    func settings() throws {
      let log = MenuLog()
      let presenter = SettingsScreenPresenter()
      presenter.open = log.log("settings")
      let action = OpenSettingsScreenAction(presenter: presenter)
      let screen = window(SettingsMenuItem(openSettings: action))
      defer { screen.close() }
      try screen.expect("Settings\u{2026}", AppShortcuts.settings, runs: "settings", log: log)
    }

    @Test("Without a signed-in window everything is disabled")
    func disabled() throws {
      let screen = window(
        Group {
          ServerFileMenuItems(actions: ServerCommandActions())
          ReconnectMenuItem(actions: nil)
          ServerMenuItems(actions: nil)
          SettingsMenuItem(openSettings: nil)
        })
      defer { screen.close() }
      let items = try screen.items
      let enabled = items.items.filter(\.isEnabled)
      #expect(items.item(named: "Sign Out of Server") != nil)
      #expect(enabled.isEmpty)
    }
  }

  @Suite("Commands: the Tab menu", .serialized)
  @MainActor
  struct CommandsTabMenuTests {
    private func allActions(_ log: MenuLog, count: Int = 3) -> TabCommandActions {
      var actions = TabCommandActions(
        newTab: log.log("new tab"), closeTab: log.log("close"), reopenClosedTab: log.log("reopen"),
        selectTab: { [log] in log.calls.append("select \($0)") }, selectNextTab: log.log("next"),
        selectPreviousTab: log.log("previous"), togglePinned: log.log("pin"),
        duplicateTab: log.log("duplicate"), moveTabToNewWindow: log.log("new window"),
        showAllTabs: log.log("all"), openBrowser: log.log("browser"),
        toggleTerminal: log.log("terminal"), count: count)
      actions.newShell = log.log("shell")
      actions.supportsSplit = true
      actions.toggleSplit = log.log("split")
      actions.focusPane = { [log] in log.calls.append("focus \($0.rawValue)") }
      actions.moveTabToOtherPane = log.log("other pane")
      return actions
    }

    @Test("Each item has its shortcut and runs its action")
    func items() throws {
      let log = MenuLog()
      let screen = window(TabMenuItems(actions: allActions(log)))
      defer { screen.close() }
      let table: [MenuItemCheck] = [
        .init("Reopen Closed Tab", AppShortcuts.reopenClosedTab, "reopen"),
        .init("Show Next Tab", AppShortcuts.nextTab, "next"),
        .init("Show Previous Tab", AppShortcuts.previousTab, "previous"),
        .init("Show All Tabs", AppShortcuts.showAllTabs, "all"),
        .init("Select Tab 1", AppShortcuts.selectTab(0), "select 0"),
        .init("Select Tab 3", AppShortcuts.selectTab(2), "select 2"),
        .init("Select Last Tab", AppShortcuts.selectTab(8), "select 8"),
        .init("Show Terminal", AppShortcuts.showTerminal, "terminal"),
        .init("New Shell", AppShortcuts.newShell, "shell"),
        .init("Pin or Unpin Tab", nil, "pin"),
        .init("Duplicate Tab", nil, "duplicate"),
        .init("Move Tab to New Window", nil, "new window"),
        .init("Move Tab to Other Pane", nil, "other pane"),
      ]
      for check in table {
        try screen.expect(check.title, check.shortcut, runs: check.call, log: log)
      }
    }

    @Test("Select Tab past the last tab is disabled, but Select Last Tab isn't")
    func selectBeyond() throws {
      let screen = window(TabMenuItems(actions: allActions(MenuLog(), count: 2)))
      defer { screen.close() }
      let items = try screen.items
      #expect(items.item(named: "Select Tab 2")?.isEnabled == true)
      #expect(items.item(named: "Select Tab 3")?.isEnabled == false)
      #expect(items.item(named: "Select Last Tab")?.isEnabled == true)
    }

    @Test("With no tabs even Select Last Tab is disabled")
    func noTabs() throws {
      let screen = window(TabMenuItems(actions: allActions(MenuLog(), count: 0)))
      defer { screen.close() }
      #expect(try screen.items.item(named: "Select Last Tab")?.isEnabled == false)
    }

    @Test("Move to New Window and Other Pane are gone when the window can't")
    func hiddenItems() throws {
      var actions = allActions(MenuLog())
      actions.moveTabToNewWindow = nil
      actions.supportsSplit = false
      let screen = window(TabMenuItems(actions: actions))
      defer { screen.close() }
      let items = try screen.items
      #expect(items.item(named: "Move Tab to New Window") == nil)
      #expect(items.item(named: "Move Tab to Other Pane") == nil)
    }

    @Test("Without a tab window everything is disabled")
    func disabled() throws {
      let screen = window(TabMenuItems(actions: nil))
      defer { screen.close() }
      let enabled = try screen.items.items.filter { !$0.isSeparatorItem && $0.isEnabled }
      #expect(enabled.isEmpty)
    }

    @Test("New Tab needs a tab window")
    func newTab() throws {
      let log = MenuLog()
      let screen = window(NewTabMenuItem(actions: allActions(log)))
      defer { screen.close() }
      try screen.expect("New Tab", AppShortcuts.newTab, runs: "new tab", log: log)
      let without = window(NewTabMenuItem(actions: nil))
      defer { without.close() }
      #expect(try without.items.item(named: "New Tab")?.isEnabled == false)
    }

    @Test("Close Tab closes the tab, and Close Window the window")
    func closeTab() throws {
      let log = MenuLog()
      let screen = window(CloseMenuItems(actions: allActions(log), closeWindow: log.log("window")))
      defer { screen.close() }
      try screen.expect("Close Tab", AppShortcuts.closeTab, runs: "close", log: log)
      try screen.expect("Close Window", AppShortcuts.closeWindow, runs: "window", log: log)
    }

    @Test("With no tab left Close Tab closes the window")
    func closeWindowWithoutTabs() throws {
      let log = MenuLog()
      var actions = allActions(log, count: 0)
      actions.closeTab = nil
      let screen = window(CloseMenuItems(actions: actions, closeWindow: log.log("window")))
      defer { screen.close() }
      try screen.expect("Close Tab", AppShortcuts.closeTab, runs: "window", log: log)
    }

    @Test("A tab that can't close disables Close Tab instead of closing the window")
    func unclosableTab() throws {
      let log = MenuLog()
      var actions = allActions(log, count: 2)
      actions.closeTab = nil
      let screen = window(CloseMenuItems(actions: actions, closeWindow: log.log("window")))
      defer { screen.close() }
      #expect(try screen.items.item(named: "Close Tab")?.isEnabled == false)
    }

    @Test("Where windows don't close there's no Close Window, and Close Tab needs a tab")
    func noWindowClosing() throws {
      let screen = window(CloseMenuItems(actions: nil, closeWindow: nil))
      defer { screen.close() }
      let items = try screen.items
      #expect(items.titles == ["Close Tab"])
      #expect(items.item(named: "Close Tab")?.isEnabled == false)
    }

    @Test("Split items follow the split, and focus either pane")
    func split() throws {
      let log = MenuLog()
      var actions = allActions(log)
      let screen = window(SplitMenuItems(actions: actions))
      defer { screen.close() }
      try screen.expect("Show Split View", AppShortcuts.toggleSplit, runs: "split", log: log)
      try screen.expect(
        "Focus Left Pane", AppShortcuts.focusLeftPane, runs: "focus leading", log: log)
      try screen.expect(
        "Focus Right Pane", AppShortcuts.focusRightPane, runs: "focus trailing", log: log)
      actions.isSplit = true
      let splitScreen = window(SplitMenuItems(actions: actions))
      defer { splitScreen.close() }
      try splitScreen.expect("Hide Split View", AppShortcuts.toggleSplit, runs: "split", log: log)
    }

    @Test("Split items are disabled without their actions")
    func splitDisabled() throws {
      let screen = window(SplitMenuItems(actions: TabCommandActions()))
      defer { screen.close() }
      let enabled = try screen.items.items.filter(\.isEnabled)
      #expect(enabled.isEmpty)
    }
  }
#endif
