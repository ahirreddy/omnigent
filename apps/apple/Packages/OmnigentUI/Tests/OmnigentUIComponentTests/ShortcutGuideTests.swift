import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("Keyboard shortcuts and palette order")
struct ShortcutGuideTests {
  @Test("Shortcut text puts modifiers in the menu bar's order and names special keys")
  func text() {
    #expect(AppShortcuts.text(AppShortcuts.reconnect) == "⌥⇧⌘R")
    #expect(AppShortcuts.text(AppShortcuts.focusComposer) == "⌃⇧L")
    #expect(AppShortcuts.text(AppShortcuts.previousTab) == "⌃⇧Tab")
    #expect(AppShortcuts.text(AppShortcuts.send) == "⌘Return")
    #expect(AppShortcuts.text(AppShortcuts.nextMessage) == "⌥⌘↓")
    #expect(AppShortcuts.text(AppShortcuts.selectTab(8)) == "⌘9")
    #expect(AppShortcuts.text(AppShortcuts.nextTabAlias) == "⇧⌘]")
  }

  @Test("No two shortcuts share keys")
  func unique() {
    let all = [
      AppShortcuts.commandPalette, AppShortcuts.findSession, AppShortcuts.keyboardShortcuts,
      AppShortcuts.previousSession, AppShortcuts.nextSession, AppShortcuts.send,
      AppShortcuts.sendAlternative, AppShortcuts.stopAgent, AppShortcuts.renameSession,
      AppShortcuts.focusComposer, AppShortcuts.jumpToLatest, AppShortcuts.previousMessage,
      AppShortcuts.nextMessage, AppShortcuts.dictate, AppShortcuts.expandEditor,
      AppShortcuts.chooseModel, AppShortcuts.cycleModel, AppShortcuts.cycleEffort,
      AppShortcuts.toggleViewMode, AppShortcuts.toggleInspector, AppShortcuts.rightPanel,
      AppShortcuts.toggleSidebar, AppShortcuts.toggleSidebarAlias, AppShortcuts.searchWorkspace,
      AppShortcuts.newTab, AppShortcuts.closeTab, AppShortcuts.reopenClosedTab,
      AppShortcuts.nextTab, AppShortcuts.previousTab, AppShortcuts.nextTabAlias,
      AppShortcuts.previousTabAlias, AppShortcuts.showAllTabs,
      AppShortcuts.showTerminal, AppShortcuts.newShell, AppShortcuts.openBrowser,
      AppShortcuts.toggleSplit, AppShortcuts.focusLeftPane, AppShortcuts.focusRightPane,
      AppShortcuts.previousPane, AppShortcuts.nextPane, AppShortcuts.newSession,
      AppShortcuts.newWindow, AppShortcuts.closeWindow, AppShortcuts.settings,
      AppShortcuts.reconnect, AppShortcuts.find, AppShortcuts.findNext, AppShortcuts.findPrevious,
      AppShortcuts.useSelectionForFind, AppShortcuts.undo,
    ]
    let numbered =
      (0..<9).map(AppShortcuts.selectTab)
      + (0..<InspectorTab.allCases.count).map(AppShortcuts.rightPanelTab)
      + (0..<10).map(AppShortcuts.pinnedSession)
    let texts = (all + numbered).map(AppShortcuts.text)
    #expect(Set(texts).count == texts.count)
  }

  @Test("The sheet lists Dictate on Option-Command-V and the shortcuts the web documents")
  func sheetContent() {
    let rows = Dictionary(
      ShortcutGuide.groups(submitWithCommandReturn: false, isMac: true).flatMap(\.rows)
        .map { ($0.title, $0.keys) }, uniquingKeysWith: { first, _ in first })
    #expect(rows["Toggle voice dictation"] == "⌥⌘V")
    #expect(rows.filter { $0.value == "⌥⌘V" }.map(\.key) == ["Toggle voice dictation"])
    #expect(rows["Paste as attachment"] == nil)
    #expect(rows["Find a session by name"] == "⌥⌘S")
    #expect(rows["Rename current session"] == "⌥⌘R")
    #expect(rows["Open pinned session 1–9 / 10"] == "⌃⌘1–9 / ⌃⌘0")
    #expect(rows["Reconnect"] == "⌥⇧⌘R")
    #expect(rows["Next / previous tab"] == "⇧⌘] / ⇧⌘[ or ⌃Tab / ⌃⇧Tab")
    #expect(rows["Search workspace contents"] == "⇧⌘F")
    #expect(rows["Select a right panel tab"] == "⌥⌘1–\(InspectorTab.allCases.count)")
    #expect(rows["Expand or collapse the editor"] == "⇧⌘E")
    #expect(rows["Previous / next message"] == "⌥⌘↑ / ⌥⌘↓")
    #expect(rows["Open model picker"] == "⌃⇧M")
    #expect(rows["Cycle model"] == "⌃⌥M")
    #expect(rows["Cycle reasoning effort"] == "⌃⌥E")
    #expect(rows["Open a new shell"] == "⌥⌘T")
    #expect(rows["Toggle sessions sidebar"] == "⌥⌘[ or ⌃⌘S")
    #expect(rows["Focus left / right pane"] == "⌥⌘← / ⌥⌘→ or ⌥⇧⌘[ / ⌥⇧⌘]")
    #expect(rows["Select tab 1–8 / last tab"] == "⌘1–8 / ⌘9")
  }

  @Test("Send keys follow the send preference; touch platforms send with Command-Return")
  func sendKeys() {
    func keys(_ title: String, commandReturn: Bool, isMac: Bool = true) -> String? {
      ShortcutGuide.groups(submitWithCommandReturn: commandReturn, isMac: isMac)
        .flatMap(\.rows).first { $0.title == title }?.keys
    }
    #expect(keys("Send message", commandReturn: false) == "Return")
    #expect(keys("New line in message", commandReturn: false) == "⇧Return or ⌥Return")
    #expect(keys("Send message", commandReturn: true) == "⌘Return")
    #expect(keys("New line in message", commandReturn: true) == "Return")
    #expect(keys("Send message", commandReturn: false, isMac: false) == "⌘Return")
    let touch = ShortcutGuide.groups(submitWithCommandReturn: false, isMac: false)
    #expect(!touch.contains { $0.title == "Windows and search" })
    #expect(!touch.flatMap(\.rows).contains { $0.title == "Open a new browser tab" })
  }

  @Test("Before typing, up to five recent sessions lead the actions")
  func idleOrder() {
    let state = PaletteViewState(scope: "Studio", sessions: (1...7).map { session("s\($0)") })
    let commands = PaletteCatalog.entries(state: state, commands: SessionCommandActions())
    let sections = PaletteResults.sections(
      scope: .all, query: " ", commands: commands, state: state, found: PaletteSearchResults())
    #expect(sections.map(\.title) == ["Sessions", "Actions"])
    #expect(sections[0].entries.map(\.id) == ["s1", "s2", "s3", "s4", "s5"])
    #expect(sections[1].entries == commands)
  }

  @Test("Typing groups sessions, then In messages, then matching actions, without repeats")
  func searchOrder() {
    let state = PaletteViewState(
      scope: "Studio", sessions: [session("deploy", title: "Deploy fix"), session("other")])
    let found = PaletteSearchResults(
      titles: [session("deploy", prefix: "found"), session("older", prefix: "found")],
      messages: [session("older", prefix: "message"), session("notes", prefix: "message")])
    let commands = PaletteCatalog.entries(state: state, commands: SessionCommandActions())
    let sections = PaletteResults.sections(
      scope: .all, query: "deploy", commands: commands, state: state, found: found)
    #expect(sections.map(\.title) == ["Sessions", "In messages"])
    #expect(sections[0].entries.map(\.id) == ["deploy", "found-older"])
    #expect(sections[1].entries.map(\.id) == ["message-notes"])
    let withActions = PaletteResults.sections(
      scope: .all, query: "inbox", commands: commands, state: state, found: found)
    #expect(withActions.last?.title == "Actions")
    #expect(withActions.last?.entries.first?.target == .inbox)
  }

  @Test("Find a session by name lists only sessions, including the server's title matches")
  func sessionsScope() {
    let state = PaletteViewState(scope: "Studio", sessions: [session("deploy", title: "Deploy")])
    let found = PaletteSearchResults(
      titles: [session("older", prefix: "found")], messages: [session("notes", prefix: "message")])
    let sections = PaletteResults.sections(
      scope: .sessions, query: "deploy",
      commands: PaletteCatalog.entries(
        state: state, commands: SessionCommandActions()), state: state, found: found)
    #expect(sections.map(\.title) == ["Sessions"])
    #expect(sections[0].entries.map(\.id) == ["deploy", "found-older"])
    var detailed = session("notes", title: "Notes")
    detailed.detail = "Ready · deploy agent"
    let byName = PaletteResults.sections(
      scope: .sessions, query: "deploy", commands: [],
      state: PaletteViewState(scope: "Studio", sessions: [detailed]), found: PaletteSearchResults())
    #expect(byName.isEmpty)
  }

  @Test("Palette titles mark the query's first match, ignoring case and accents")
  func highlight() {
    let marked = PaletteSearch.highlighted("Déploy the Deploy bot", query: " deploy ")
    let strong = marked.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
    #expect(strong.map { String(marked[$0.range].characters) } == ["Déploy"])
    let plain = PaletteSearch.highlighted("Deploy", query: "xyz")
    #expect(plain.runs.allSatisfy { $0.inlinePresentationIntent == nil })
  }

  private func session(_ id: String, title: String? = nil, prefix: String? = nil) -> PaletteEntry {
    PaletteEntry(
      id: prefix.map { "\($0)-\(id)" } ?? id, title: title ?? id, symbol: "bubble",
      target: .session(id))
  }
}
