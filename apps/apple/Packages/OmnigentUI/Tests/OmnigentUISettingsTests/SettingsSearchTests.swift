import Testing

@testable import OmnigentUIComponents

@Suite("Settings search: the index and its matches")
@MainActor
struct SettingsSearchTests {
  private func entries(
    categories: [String] = ["General", "Appearance", "Servers"],
    panes: [ServerSettingsPane] = [.harnesses, .archived], isMac: Bool = true
  ) -> [SettingsSearchEntry] {
    SettingsSearchIndex.entries(
      SettingsSearchScope(
        categories: categories, serverPanes: panes,
        serversCategory: isMac ? "Servers" : nil, isMac: isMac))
  }

  @Test("Only what this build, server and account show is offered")
  func scope() {
    let all = entries()
    #expect(all.contains { $0.title == "Send with Command-Return" })
    #expect(all.contains { $0.title == "Mode" && $0.location == "Appearance › Theme" })
    #expect(all.contains { $0.target == .serverPane(.archived) && $0.anchor != nil })
    // A category or pane not shown, and its rows, are left out.
    #expect(!all.contains { $0.title == "Copying from terminals" })
    #expect(!all.contains { $0.target == .serverPane(.advisor) })
    #expect(!all.contains { $0.title == "Session title instructions" })
    // Mac-only rows stay off iPhone and iPad, and so do the Mac's menu-bar shortcuts.
    let touch = entries(isMac: false)
    #expect(entries().contains { $0.title == "Browser engine" })
    #expect(!touch.contains { $0.title == "Browser engine" })
    #expect(!touch.contains { $0.title == "Use selection for Find" })
    #expect(touch.contains { $0.target == .serverPane(.harnesses) && $0.location == "Server" })
  }

  @Test("A title that starts with the words ranks first; other words find the rest")
  func words() {
    let all = entries()
    #expect(SettingsSearchIndex.results("send", in: all).first?.title == "Send with Command-Return")
    #expect(SettingsSearchIndex.results("dark", in: all).map(\.title).contains("Mode"))
    #expect(SettingsSearchIndex.results("harnesses", in: all).first?.title == "Harnesses")
    #expect(SettingsSearchIndex.results("   ", in: all).isEmpty)
    #expect(SettingsSearchIndex.results("no such setting", in: all).isEmpty)
  }

  @Test("A chord finds the shortcut bound to exactly those keys, however it's typed")
  func chords() {
    let all = entries()
    for query in ["opt cmd s", "⌥⌘S", "cmd+option+s", "⌘⌥s"] {
      let found = SettingsSearchIndex.results(query, in: all).map(\.title)
      #expect(found == ["Find a session by name"], "\(query)")
    }
    #expect(
      SettingsSearchIndex.results("shift cmd a", in: all).map(\.title) == [
        "Archive current session"
      ])
    // Fewer modifiers name another chord, not this one.
    #expect(
      !SettingsSearchIndex.results("cmd a", in: all).map(\.title).contains(
        "Archive current session"))
  }

  @Test("Shortcut text names each of its chords")
  func chordText() {
    let chords = SettingsSearchChord.chords(in: "⌃⌘1–9 / ⌃⌘0")
    #expect(chords.map(\.key) == ["1", "0"])
    #expect(chords.allSatisfy { $0.modifiers == "⌃⌘" })
    #expect(SettingsSearchChord.chords(in: "Esc or ⌘.").map(\.key) == ["."])
    #expect(SettingsSearchChord(query: "shift") == nil)
    #expect(SettingsSearchChord(query: "cmd settings") == nil)
    #expect(SettingsSearchChord(query: "cmd return")?.key == "RETURN")
  }
}
