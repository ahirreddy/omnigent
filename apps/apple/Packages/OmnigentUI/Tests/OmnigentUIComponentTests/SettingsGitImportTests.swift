#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Git and import, clicked", .serialized)
  @MainActor
  struct SettingsGitImportTests {
    private let log = ActionLog()
    private let store: UserDefaults

    init() throws {
      store = try #require(UserDefaults(suiteName: "settings-git-\(UUID())"))
    }

    @Test("each Git preference writes the web's key")
    func git() throws {
      let screen = settingsForm(store: store) { GitSettingsPane(archiveWorktreeCleanup: true) }
      defer { screen.close() }
      try screen.click(try #require(screen.switches.first))
      #expect(store.bool(forKey: GitPreferences.alwaysUseWorktreeKey))
      try screen.replaceText(in: try #require(screen.textFields.first), with: "main")
      #expect(store.string(forKey: GitPreferences.defaultBaseBranchKey) == "main")
      try screen.choose("Keep the worktree", inPopUp: try #require(screen.popUps.first))
      #expect(store.string(forKey: GitPreferences.deleteWorktreesOnArchiveKey) == "false")
      try screen.choose("Delete the worktree", inPopUp: try #require(screen.popUps.first))
      #expect(store.string(forKey: GitPreferences.deleteWorktreesOnArchiveKey) == "true")
    }

    @Test("a server that can't clean up worktrees doesn't ask about them")
    func gitWithoutCleanup() {
      let screen = settingsForm(store: store) { GitSettingsPane(archiveWorktreeCleanup: false) }
      defer { screen.close() }
      #expect(screen.popUps.isEmpty)
    }

    private var hosts: [SettingChoice] {
      [SettingChoice(id: "m1", title: "Build Mac"), SettingChoice(id: "m2", title: "Laptop")]
    }

    private var sources: [SettingChoice] {
      [
        SettingChoice(id: "all", title: "All harnesses"),
        SettingChoice(id: "codex", title: "Codex"),
        SettingChoice(id: "claude", title: "Claude Code"),
      ]
    }

    private func importActions(result: String? = "Imported 3") -> ServerSettingsActions {
      var actions = ServerSettingsActions()
      let log = log
      actions.importSessions = { host, source, limit, exact in
        log.record("import \(host) \(source) \(limit) \(exact ?? "-")")
        return result
      }
      return actions
    }

    @Test("no machine online says what to do, and offers nothing to import")
    func noHosts() throws {
      let screen = settingsForm(store: store) {
        ImportSessionsPane(hosts: [], sources: sources, actions: importActions())
      }
      defer { screen.close() }
      #expect(try screen.shows("No machine is online."))
      #expect(screen.popUps.isEmpty)
    }

    @Test("importing recent sessions sends the machine, harness and limit chosen")
    func recent() async throws {
      let actions = importActions()
      let hosts = hosts
      let sources = sources
      let screen = settingsForm(store: store) {
        ImportSessionsPane(hosts: hosts, sources: sources, actions: actions)
      }
      defer { screen.close() }
      #expect(try screen.shows("Sessions already imported are skipped."))
      try screen.choose(
        "Laptop", inPopUp: try #require(screen.popUps.first { $0.title == "Build Mac" }))
      try screen.choose(
        "Codex", inPopUp: try #require(screen.popUps.first { $0.title == "All harnesses" }))
      try screen.choose(
        "100 sessions", inPopUp: try #require(screen.popUps.first { $0.title == "25 sessions" }))
      try screen.clickButton(at: 0)
      try await screen.letTasksRun()
      #expect(log.entries == ["import m2 codex 100 -"])
      #expect(try screen.shows("Imported 3"))
    }

    @Test("importing one session needs its id, and never sends All")
    func oneSession() async throws {
      let actions = importActions()
      let hosts = hosts
      let sources = sources
      let screen = settingsForm(store: store) {
        ImportSessionsPane(hosts: hosts, sources: sources, actions: actions)
      }
      defer { screen.close() }
      try screen.choose(
        "Session by ID",
        inPopUp: try #require(screen.popUps.first { $0.title == "Recent sessions" }))
      #expect(screen.popUps.contains { $0.title == "Claude Code" }, "All is not one harness")
      #expect(screen.buttonFrames.isEmpty, "Import is off without an id")
      let field = try #require(screen.textFields.first)
      try screen.replaceText(in: field, with: " abc ")
      try screen.clickButton(at: 0)
      try await screen.letTasksRun()
      #expect(log.entries == ["import m1 claude 25 abc"])
      #expect(try screen.shows("The harness's own id for the session"))
    }

    @Test("Return in the id field imports, when it can")
    func returnImports() async throws {
      let actions = importActions()
      let hosts = hosts
      let sources = sources
      let screen = settingsForm(store: store) {
        ImportSessionsPane(hosts: hosts, sources: sources, actions: actions)
      }
      defer { screen.close() }
      try screen.choose(
        "Session by ID",
        inPopUp: try #require(screen.popUps.first { $0.title == "Recent sessions" }))
      let field = try #require(screen.textFields.first)
      try screen.click(field)
      try screen.press(keyCode: 36, characters: "\r")
      try await screen.letTasksRun()
      #expect(log.entries.isEmpty, "no id yet")
      try screen.replaceText(in: field, with: "abc")
      try screen.press(keyCode: 36, characters: "\r")
      try await screen.letTasksRun()
      #expect(log.entries == ["import m1 claude 25 abc"])
    }

    @Test("without an import action, Import stays off")
    func noImportAction() {
      let hosts = hosts
      let sources = sources
      let screen = settingsForm(store: store) {
        ImportSessionsPane(hosts: hosts, sources: sources, actions: ServerSettingsActions())
      }
      defer { screen.close() }
      #expect(screen.buttonFrames.isEmpty)
    }
  }
#endif
