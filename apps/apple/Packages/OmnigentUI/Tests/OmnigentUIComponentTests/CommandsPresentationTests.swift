#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @MainActor
  private final class CommandLog {
    var events: [String] = []
    var palette: PaletteCommandActions?
  }

  /// A window's root with the palette attached, publishing a session's commands like a real one.
  private struct PaletteRoot: View {
    let log: CommandLog
    var initiallyPresented = false
    var publishesCommands = true
    var tabs: TabCommandActions?

    var body: some View {
      RootContent(log: log, publishesCommands: publishesCommands, tabs: tabs)
        .commandPalette(
          state: PaletteViewState(
            scope: "Studio",
            sessions: [
              PaletteEntry(
                id: "a", title: "Alpha", detail: "", symbol: "bubble.left", target: .session("a"))
            ], servers: [], hasNextRequest: false),
          actions: PaletteActions { log.events.append("perform \($0)") },
          initiallyPresented: initiallyPresented)
    }
  }

  private struct RootContent: View {
    let log: CommandLog
    let publishesCommands: Bool
    let tabs: TabCommandActions?
    @Environment(\.openCommandPalette) private var open
    @FocusedValue(\.paletteCommands) private var palette
    @State private var commandRelay = FocusedActionsRelay<SessionCommandActions>()

    private var commands: SessionCommandActions? {
      guard publishesCommands else { return nil }
      var commands = SessionCommandActions()
      commands.focusComposer = { log.events.append("focus composer") }
      commands.toggleViewMode = { log.events.append("toggle view") }
      commands.openChanges = { log.events.append("open changes") }
      commands.toggleInspector = { log.events.append("toggle inspector") }
      return commands
    }

    var body: some View {
      log.palette = palette
      return Button("Open") { open?() }
        .focusedSceneValue(\.sessionCommands, commandRelay.publish(commands))
        .focusedSceneValue(\.tabCommands, tabs)
    }
  }

  @Suite("Commands: the palette presented over a window", .serialized)
  @MainActor
  struct CommandsPresentationTests {
    private func field<V: View>(_ screen: OffscreenWindow<V>) throws -> NSTextField {
      let fields = screen.allViews.compactMap { $0 as? NSTextField }.filter(\.isEditable)
      return try #require(fields.first)
    }

    private func open(_ log: CommandLog, publishes: Bool = true) throws
      -> OffscreenWindow<PaletteRoot>
    {
      let screen = OffscreenWindow(
        PaletteRoot(log: log, publishesCommands: publishes), width: 640, height: 560)
      try screen.clickControl(at: 0)
      #expect(screen.window.attachedSheet != nil)
      return screen
    }

    @Test("the environment's action opens it, and the result runs after it closes")
    func runsAfterClosing() throws {
      let log = CommandLog()
      let screen = try open(log)
      defer { screen.close() }
      #expect(log.events.isEmpty)
      try screen.press(keyCode: 36, characters: "\r")
      screen.settle(0.2)
      #expect(screen.window.attachedSheet == nil)
      #expect(log.events == ["perform session(\"a\")"])
    }

    @Test("Escape closes it without running anything")
    func escapeCloses() throws {
      let log = CommandLog()
      let screen = OffscreenWindow(
        PaletteRoot(log: log, initiallyPresented: true), width: 640, height: 560)
      defer { screen.close() }
      #expect(screen.window.attachedSheet != nil)
      try screen.press(keyCode: 53, characters: "\u{1B}")
      screen.settle(0.2)
      #expect(screen.window.attachedSheet == nil)
      #expect(log.events.isEmpty)
    }

    @Test("the session actions run the commands focused when the palette opened")
    func sessionActions() throws {
      let log = CommandLog()
      // Down from Alpha: New chat, Inbox, Settings, Sidebar, Workspace, Find, Changes, Composer,
      // Terminal, each enabled because a session is focused.
      let expected: [(downs: Int, event: String)] = [
        (8, "focus composer"), (9, "toggle view"), (7, "open changes"), (5, "toggle inspector"),
      ]
      for (downs, event) in expected {
        log.events = []
        let screen = try open(log)
        defer { screen.close() }
        for _ in 0..<downs { try screen.press(keyCode: 125, characters: "\u{F701}") }
        try screen.press(keyCode: 36, characters: "\r")
        screen.settle(0.2)
        #expect(log.events == [event], "\(downs)")
      }
    }

    @Test("without a focused session its actions can't run")
    func noSession() throws {
      let log = CommandLog()
      let screen = try open(log, publishes: false)
      defer { screen.close() }
      // Down from Alpha: New chat, Inbox, Settings, Sidebar, Find, Switch server: nothing else.
      for _ in 0..<6 { try screen.press(keyCode: 125, characters: "\u{F701}") }
      #expect(screen.window.attachedSheet != nil)
      try screen.press(keyCode: 36, characters: "\r")
      screen.settle(0.2)
      #expect(try field(screen).placeholderString == "Find a server")
      #expect(log.events.isEmpty)
      #expect(screen.window.attachedSheet != nil)
    }

    @Test("the menu's Find Session opens scoped, and Keyboard Shortcuts opens its sheet")
    func menuCommands() throws {
      let log = CommandLog()
      let screen = OffscreenWindow(PaletteRoot(log: log), width: 640, height: 560)
      defer { screen.close() }
      let palette = try #require(log.palette)
      palette.findSession()
      screen.settle(0.2)
      #expect(try field(screen).placeholderString == "Search sessions by name")
      try screen.press(keyCode: 53, characters: "\u{1B}")
      screen.settle(0.2)
      #expect(screen.window.attachedSheet == nil)
      palette.openPalette()
      screen.settle(0.2)
      #expect(try field(screen).placeholderString == "Search sessions or run a command")
      try screen.press(keyCode: 53, characters: "\u{1B}")
      screen.settle(0.2)
      palette.openShortcuts()
      screen.settle(0.2)
      #expect(screen.window.attachedSheet != nil)
      #expect(try screen.shows("Keyboard shortcuts"))
      try screen.clickControl(at: screen.controlFrames.count - 1)
      screen.settle(0.2)
      #expect(screen.window.attachedSheet == nil)
    }

    /// Presses a key as a real keyboard reports it: Option changes the characters but not the
    /// ones ignoring modifiers.
    private func pressReal<V: View>(
      _ screen: OffscreenWindow<V>, _ characters: String, ignoring: String,
      _ flags: NSEvent.ModifierFlags
    ) throws {
      let event = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
          windowNumber: screen.window.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: 33))
      screen.window.sendEvent(event)
      screen.settle(0.02)
    }

    @Test("Option-Command-[ toggles the sidebar even in a split window; Shift moves between panes")
    func aliases() throws {
      let log = CommandLog()
      var tabs = TabCommandActions()
      tabs.focusPane = { log.events.append("pane \($0)") }
      let screen = OffscreenWindow(PaletteRoot(log: log, tabs: tabs), width: 640, height: 560)
      defer { screen.close() }
      try pressReal(screen, "\u{201C}", ignoring: "[", [.command, .option])
      #expect(log.events == ["perform toggleSidebar"])
      log.events = []
      try pressReal(screen, "\u{201D}", ignoring: "{", [.command, .option, .shift])
      try pressReal(screen, "\u{2019}", ignoring: "}", [.command, .option, .shift])
      #expect(log.events == ["pane leading", "pane trailing"])
    }

    @Test("Shift-Command-] and Shift-Command-[ show the next and previous tab")
    func tabAliases() throws {
      let log = CommandLog()
      var tabs = TabCommandActions()
      tabs.selectNextTab = { log.events.append("next tab") }
      tabs.selectPreviousTab = { log.events.append("previous tab") }
      let screen = OffscreenWindow(PaletteRoot(log: log, tabs: tabs), width: 640, height: 560)
      defer { screen.close() }
      try pressReal(screen, "}", ignoring: "}", [.command, .shift])
      try pressReal(screen, "{", ignoring: "{", [.command, .shift])
      #expect(log.events == ["next tab", "previous tab"])
    }

    @Test("with one tab the tab keys do nothing")
    func tabAliasesWithOneTab() throws {
      let log = CommandLog()
      let screen = OffscreenWindow(
        PaletteRoot(log: log, tabs: TabCommandActions()), width: 640, height: 560)
      defer { screen.close() }
      try pressReal(screen, "}", ignoring: "}", [.command, .shift])
      #expect(log.events.isEmpty)
    }

    @Test("without split panes the pane keys do nothing, and the sidebar key still works")
    func aliasesWithoutSplit() throws {
      let log = CommandLog()
      let screen = OffscreenWindow(PaletteRoot(log: log), width: 640, height: 560)
      defer { screen.close() }
      try pressReal(screen, "\u{201D}", ignoring: "{", [.command, .option, .shift])
      #expect(log.events.isEmpty)
      try pressReal(screen, "\u{201C}", ignoring: "[", [.command, .option])
      #expect(log.events == ["perform toggleSidebar"])
    }

    @Test("the shortcuts sheet lists the guide's rows, and send keys follow the preference")
    func shortcutsSheet() throws {
      defer {
        UserDefaults.standard.removeObject(forKey: ComposerPreferences.submitWithCommandReturnKey)
      }
      UserDefaults.standard.set(true, forKey: ComposerPreferences.submitWithCommandReturnKey)
      let commandReturn = OffscreenWindow(KeyboardShortcutsSheet(), width: 560, height: 700)
      defer { commandReturn.close() }
      let groups = ShortcutGuide.groups(submitWithCommandReturn: true, isMac: true)
      let first = try #require(groups.first?.rows.first)
      #expect(try commandReturn.shows(first.title))
      #expect(try commandReturn.shows(first.keys))
    }
  }

  @Suite("Commands: forwarding keeps menus current")
  @MainActor
  struct CommandsForwardingTests {
    @Test("server commands forward to the newest actions, and report which are enabled")
    func serverCommands() {
      var log: [String] = []
      func actions(_ tag: String) -> ServerCommandActions {
        var actions = ServerCommandActions(
          reconnect: { log.append("\(tag) reconnect") },
          changeServer: { log.append("\(tag) change") }, signOut: { log.append("\(tag) out") })
        actions.newSession = { log.append("\(tag) new") }
        actions.newWindow = { log.append("\(tag) window") }
        return actions
      }
      #expect(ServerCommandActions().menuSignature == [false, false, false, false, false])
      let latest = actions("new")
      #expect(latest.menuSignature == [true, true, true, true, true])
      let forwarded = actions("old").forwarding { latest }
      forwarded.reconnect?()
      forwarded.changeServer?()
      forwarded.signOut?()
      forwarded.newSession?()
      forwarded.newWindow?()
      #expect(log == ["new reconnect", "new change", "new out", "new new", "new window"])
      log = []
      let gone = actions("old").forwarding { nil }
      gone.reconnect?()
      #expect(log.isEmpty)
      #expect(ServerCommandActions().forwarding { latest }.reconnect == nil)
    }

    @Test("palette commands forward to the newest actions")
    func paletteCommands() {
      var log: [String] = []
      let latest = PaletteCommandActions(
        openPalette: { log.append("palette") }, openShortcuts: { log.append("shortcuts") },
        findSession: { log.append("find") })
      #expect(latest.menuSignature)
      let forwarded = PaletteCommandActions(
        openPalette: {}, openShortcuts: {}, findSession: {}
      ).forwarding { latest }
      forwarded.openPalette()
      forwarded.openShortcuts()
      forwarded.findSession()
      #expect(log == ["palette", "shortcuts", "find"])
      log = []
      let gone = latest.forwarding { nil }
      gone.openPalette()
      gone.openShortcuts()
      gone.findSession()
      #expect(log.isEmpty)
    }

    @Test("A session's commands reach the newest ones, and nil stays nil")
    func sessionCommands() {
      var log: [String] = []
      func make(_ tag: String) -> SessionCommandActions {
        func entry(_ name: String) -> @MainActor () -> Void { { log.append("\(tag) \(name)") } }
        var actions = SessionCommandActions(
          send: entry("send"), interrupt: entry("stop"), jumpToLatest: entry("latest"),
          focusComposer: entry("composer"), toggleInspector: entry("inspector"),
          previousSession: entry("previous"), nextSession: entry("next"),
          toggleViewMode: entry("mode"), openChanges: entry("changes"))
        actions.rename = entry("rename")
        actions.chooseModel = entry("choose")
        actions.cycleModel = entry("model")
        actions.cycleEffort = entry("effort")
        actions.approveOwnsCommandReturn = true
        return actions
      }
      let latest = make("latest")
      let forwarded = make("old").forwarding { latest }
      #expect(forwarded.menuSignature == latest.menuSignature)
      #expect(forwarded.approveOwnsCommandReturn)
      let items = [
        forwarded.send, forwarded.interrupt, forwarded.jumpToLatest, forwarded.focusComposer,
        forwarded.toggleInspector, forwarded.previousSession, forwarded.nextSession,
        forwarded.toggleViewMode, forwarded.openChanges, forwarded.rename, forwarded.chooseModel,
        forwarded.cycleModel, forwarded.cycleEffort,
      ]
      for item in items { item?() }
      #expect(log.count == 13)
      let fromLatest = log.filter { $0.hasPrefix("latest ") }
      #expect(fromLatest.count == 13)
      #expect(SessionCommandActions().forwarding { latest }.send == nil)
      #expect(SessionCommandActions().menuSignature.allSatisfy { !$0 })
    }

    @Test("A window's tab commands reach the newest ones, and keep the menu's state")
    func tabCommands() {
      var log: [String] = []
      func make(_ tag: String, count: Int) -> TabCommandActions {
        func entry(_ name: String) -> @MainActor () -> Void { { log.append("\(tag) \(name)") } }
        var actions = TabCommandActions(
          newTab: entry("new"), closeTab: entry("close"), reopenClosedTab: entry("reopen"),
          selectTab: { log.append("\(tag) select \($0)") }, selectNextTab: entry("next"),
          selectPreviousTab: entry("previous"), togglePinned: entry("pin"),
          duplicateTab: entry("duplicate"), moveTabToNewWindow: entry("tear"),
          showAllTabs: entry("all"), openBrowser: entry("browser"),
          toggleTerminal: entry("terminal"), count: count)
        actions.supportsSplit = true
        actions.isSplit = true
        actions.toggleSplit = entry("split")
        actions.focusPane = { log.append("\(tag) focus \($0.rawValue)") }
        actions.moveTabToOtherPane = entry("other pane")
        actions.newShell = entry("shell")
        return actions
      }
      let latest = make("latest", count: 3)
      let forwarded = make("old", count: 3).forwarding { latest }
      #expect(forwarded.menuSignature == latest.menuSignature)
      #expect(forwarded.count == 3)
      #expect(forwarded.supportsSplit && forwarded.isSplit)
      forwarded.newTab()
      forwarded.selectTab(2)
      forwarded.focusPane?(.trailing)
      let items = [
        forwarded.closeTab, forwarded.reopenClosedTab, forwarded.selectNextTab,
        forwarded.selectPreviousTab, forwarded.togglePinned, forwarded.duplicateTab,
        forwarded.moveTabToNewWindow, forwarded.showAllTabs, forwarded.openBrowser,
        forwarded.toggleTerminal, forwarded.toggleSplit, forwarded.moveTabToOtherPane,
        forwarded.newShell,
      ]
      for item in items { item?() }
      #expect(log.count == 16)
      let fromLatest = log.filter { $0.hasPrefix("latest ") }
      #expect(fromLatest.count == 16)
      #expect(log.contains("latest select 2"))
      #expect(log.contains("latest focus trailing"))
      let none = TabCommandActions().forwarding { latest }
      #expect(none.closeTab == nil)
      #expect(none.focusPane == nil)
      #expect(make("a", count: 1).menuSignature != make("a", count: 2).menuSignature)
    }

    @Test("every tab and right panel key is well formed across the indexes the app asks for")
    func indexedShortcuts() {
      for index in 0..<9 {
        _ = AppShortcuts.selectTab(index)
      }
      for index in 0..<6 {
        _ = AppShortcuts.rightPanelTab(index)
      }
    }
  }
#endif
