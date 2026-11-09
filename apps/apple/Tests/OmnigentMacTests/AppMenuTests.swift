import AppKit
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// The app's menus as SwiftUI built them from the scene's commands. Read only: nothing is invoked.
/// Routing a command to a window needs a real key window, which runs in the VM.
@MainActor
struct AppMenuTests {
  private struct Entry {
    let path: String
    let item: NSMenuItem

    /// Its shortcut, as modifiers then key; empty when it has none.
    var shortcut: String {
      let key = item.keyEquivalent
      guard !key.isEmpty else { return "" }
      let flags = item.keyEquivalentModifierMask
      var text = ""
      if flags.contains(.control) { text += "ctrl+" }
      if flags.contains(.option) { text += "opt+" }
      if flags.contains(.shift) { text += "shift+" }
      if flags.contains(.command) { text += "cmd+" }
      return text + key
    }
  }

  private func entries(in menu: NSMenu, prefix: String = "") -> [Entry] {
    menu.items.flatMap { item -> [Entry] in
      let path = prefix + item.title
      guard let submenu = item.submenu else { return [Entry(path: path, item: item)] }
      return entries(in: submenu, prefix: path + " > ")
    }
  }

  /// Every top-level menu's items, the application menu named `App` whatever the edition calls it.
  private func allEntries() throws -> [Entry] {
    let main = try #require(NSApp.mainMenu)
    return main.items.enumerated().flatMap { index, top -> [Entry] in
      guard let submenu = top.submenu else { return [] }
      return entries(in: submenu, prefix: (index == 0 ? "App" : top.title) + " > ")
    }
  }

  @Test func theMenusAreInTheirOrder() throws {
    let main = try #require(NSApp.mainMenu)
    let titles = main.items.dropFirst().map(\.title)
    var expected = ["File", "Edit", "View", "Server", "Browser", "Tab", "Navigate", "Conversation"]
    if DebugCommands.isEnabled { expected.append("Debug") }
    #expect(titles == expected + ["Window", "Help"])
  }

  @Test(arguments: [
    ("App > Settings…", "cmd+,"), ("App > Quit", "cmd+q"), ("File > New Session", "cmd+n"),
    ("File > New Window", "shift+cmd+n"), ("File > New Tab", "cmd+t"),
    ("File > Close Tab", "cmd+w"), ("Edit > Undo", "cmd+z"), ("Edit > Find > Find…", "cmd+f"),
    ("View > Show Browser", "opt+cmd+b"), ("Browser > Developer Tools", "opt+cmd+i"),
    ("Tab > Reopen Closed Tab", "shift+cmd+t"), ("Tab > Show All Tabs", "shift+cmd+\\"),
    ("Tab > Select Tab 1", "cmd+1"), ("Tab > Select Last Tab", "cmd+9"),
    ("Tab > Show Terminal", "ctrl+`"), ("Navigate > Command Palette…", "cmd+k"),
    ("Navigate > Find Session by Name…", "opt+cmd+s"),
    ("Navigate > Keyboard Shortcuts…", "cmd+/"), ("Conversation > Stop Agent", "cmd+."),
    ("Conversation > Rename Session…", "opt+cmd+r"),
    ("Conversation > Focus Composer", "ctrl+shift+l"),
    ("Conversation > Previous Session", "cmd+["), ("Conversation > Next Session", "cmd+]"),
  ])
  func aCommandKeepsItsShortcut(path: String, expected: String) throws {
    // The application menu's Quit carries the edition's name.
    let entry = try #require(try allEntries().first { $0.path.hasPrefix(path) }, "no \(path)")
    #expect(entry.shortcut == expected)
  }

  /// Two commands on one shortcut leave one of them unreachable by keyboard. The one pair here
  /// shares ⌥⌘I: on a browser tab it opens Developer Tools, the earlier menu, not the right panel.
  @Test func noOtherCommandsShareAShortcut() throws {
    let all = try allEntries().filter { !$0.shortcut.isEmpty && !$0.item.isHidden }
    let grouped = Dictionary(grouping: all, by: \.shortcut)
    let shared = grouped.filter { $0.value.count > 1 }.mapValues { $0.map(\.path) }
    #expect(
      shared == ["opt+cmd+i": ["Browser > Developer Tools", "Conversation > Toggle Right Panel"]])
  }

  @Test func checkForUpdatesIsOnlyInTheEditionThatUpdatesItself() throws {
    let paths = try allEntries().map(\.path)
    #if OMNIGENT_CHROMIUM
      #expect(paths.contains("App > Check for Updates…"))
    #else
      #expect(!paths.contains("App > Check for Updates…"))
    #endif
  }

  @Test func theDebugMenuIsOnlyInADebugBuild() throws {
    let paths = try allEntries().map(\.path)
    #expect(paths.contains("Debug > Show Core Inspector") == DebugCommands.isEnabled)
  }

  @Test func helpLeadsToTheDocs() throws {
    let paths = try allEntries().map(\.path)
    #expect(paths.contains("Help > Omnigent Help"))
    #expect(OmnigentMacApp.helpURL?.scheme == "https")
  }
}
