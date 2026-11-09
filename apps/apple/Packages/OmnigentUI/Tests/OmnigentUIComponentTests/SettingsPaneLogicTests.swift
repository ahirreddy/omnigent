import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Settings pane rules")
struct SettingsPaneLogicTests {
  private func service(
    connected: Bool, tools: [String] = [], detail: String = ""
  ) -> MCPServiceRow {
    MCPServiceRow(id: "s", name: "Service", detail: detail, isConnected: connected, tools: tools)
  }

  @Test("an MCP row says its status and counts its tools in good English")
  func mcpDetail() {
    #expect(MCPPane.detail(service(connected: false), testResult: nil) == "Not connected")
    #expect(MCPPane.detail(service(connected: true), testResult: nil) == "Connected")
    #expect(
      MCPPane.detail(service(connected: true, tools: ["a"]), testResult: nil)
        == "Connected \u{00B7} 1 tool")
    #expect(
      MCPPane.detail(service(connected: true, tools: ["a", "b"], detail: "Docs"), testResult: nil)
        == "Docs \u{00B7} Connected \u{00B7} 2 tools")
  }

  @Test("a test's result shows only while the service is connected")
  func mcpTestResult() {
    #expect(MCPPane.detail(service(connected: true), testResult: "3 tools OK") == "3 tools OK")
    #expect(MCPPane.detail(service(connected: false), testResult: "3 tools OK") == "Not connected")
  }

  @Test("a connected provider never reads as not connected")
  func providerStatus() {
    func status(_ connected: Bool, _ account: String?) -> String {
      IntegrationsPane.status(
        ProviderConnectionRow(id: "p", name: "GitHub", isConnected: connected, account: account))
    }
    #expect(status(true, "octocat") == "Connected as octocat")
    #expect(status(true, nil) == "Connected")
    #expect(status(false, nil) == "Not connected")
    #expect(status(false, "stale") == "Not connected")
  }

  @Test("Import keeps the chosen machine only while the picker lists it")
  func importHost() {
    let hosts = [SettingChoice(id: "a", title: "A"), SettingChoice(id: "b", title: "B")]
    #expect(ImportSessionsPane.liveHost(nil, in: hosts) == "a")
    #expect(ImportSessionsPane.liveHost("b", in: hosts) == "b")
    #expect(ImportSessionsPane.liveHost("gone", in: hosts) == "a")
    #expect(ImportSessionsPane.liveHost("a", in: []) == nil)
  }

  @Test("importing one session picks a real harness, never All")
  func importSource() {
    func choices(_ ids: String...) -> [SettingChoice] {
      ids.map { SettingChoice(id: $0, title: $0) }
    }
    #expect(
      ImportSessionsPane.singleSource("all", in: choices("all", "codex", "claude")) == "claude")
    #expect(ImportSessionsPane.singleSource("all", in: choices("all", "codex")) == "codex")
    #expect(ImportSessionsPane.singleSource("codex", in: choices("all", "claude")) == "codex")
    #expect(ImportSessionsPane.singleSource("all", in: choices("all")) == "all")
    #expect(ImportSessionsPane.singleSource("all", in: []) == "all")
    #expect(ImportMode.allCases.map(\.title) == ["Recent sessions", "Session by ID"])
  }

  @Test("an MCP server needs a free name and a real endpoint")
  func mcpProblems() {
    func problem(
      name: String = "docs", transport: String = "http", url: String = "https://x.dev/mcp",
      command: String = "", credentials: [MCPCredentialEdit] = [], taken: Set<String> = []
    ) -> String? {
      MCPServerEditorSheet.problem(
        in: MCPServerEdit(
          name: name, isNew: true, transport: transport, url: url, command: command,
          credentials: credentials), taken: taken)
    }
    #expect(problem() == nil)
    #expect(problem(url: "  HTTP://x.dev ") == nil, "scheme case and stray spaces don't matter")
    #expect(problem(name: "  ") == "Name the server.")
    #expect(problem(name: " docs ", taken: ["docs"]) == "Another MCP server has this name.")
    for bad in ["", "x.dev", "ftp://x.dev", "http://", "https:///path", "javascript:alert(1)"] {
      #expect(problem(url: bad) == "Use an HTTP or HTTPS URL.", "\(bad)")
    }
    #expect(problem(transport: "stdio", url: "", command: "  ") == "Enter the command.")
    #expect(problem(transport: "stdio", url: "", command: "npx") == nil)
    let unnamed = [MCPCredentialEdit(name: " ", existing: false)]
    #expect(problem(credentials: unnamed) == "Name each header.")
    #expect(
      problem(transport: "stdio", command: "npx", credentials: unnamed) == "Name each variable.")
  }

  @Test("a saved MCP server loses a paste's stray spaces, and a new one takes its name")
  func mcpFinished() {
    let new = MCPServerEditorSheet.finished(
      MCPServerEdit(name: " docs ", isNew: true, url: " https://x.dev ", command: " npx "))
    #expect(new.name == "docs")
    #expect(new.originalName == "docs")
    #expect(new.url == "https://x.dev")
    #expect(new.command == "npx")
    let stored = MCPServerEditorSheet.finished(
      MCPServerEdit(name: "docs", originalName: "old", isNew: false))
    #expect(stored.originalName == "old")
  }

  @Test("spaces alone aren't a harness search")
  func harnessEmptyMessage() {
    let none = "No configured harnesses."
    #expect(HarnessesSettingsSection.emptyMessage(query: "") == none)
    #expect(HarnessesSettingsSection.emptyMessage(query: "   ") == none)
    #expect(
      HarnessesSettingsSection.emptyMessage(query: " codex ")
        == "No harnesses match \u{201C}codex\u{201D}.")
  }

  @Test("a settings file's version is any number from 1, and not a Boolean")
  func fileVersion() throws {
    func file(_ version: String) -> Data {
      Data(#"{"version": \#(version), "settings": {"web-theme": "dark"}}"#.utf8)
    }
    #expect(try SettingsPortability.settings(in: file("1")) == ["web-theme": "dark"])
    #expect(try SettingsPortability.settings(in: file("2.5")) == ["web-theme": "dark"])
    for bad in ["true", "false", "0", "-1", "\"1\"", "null"] {
      #expect(throws: SettingsPortability.ImportError.notSettings) {
        try SettingsPortability.settings(in: file(bad))
      }
    }
    #expect(throws: SettingsPortability.ImportError.invalidJSON) {
      try SettingsPortability.settings(in: Data("{".utf8))
    }
    #expect(SettingsPortability.ImportError.invalidJSON.description.contains("invalid JSON"))
    #expect(SettingsPortability.ImportError.notSettings.description.contains("valid Omnigent"))
  }

  @Test("stored numbers read as the web's text, however extreme")
  func numberText() {
    #expect(SettingsPortability.text(nil) == nil)
    #expect(SettingsPortability.text("x") == "x")
    #expect(SettingsPortability.text(true) == "true")
    #expect(SettingsPortability.text(false) == "false")
    #expect(SettingsPortability.text(14.0) == "14")
    #expect(SettingsPortability.text(1.5) == "1.5")
    #expect(SettingsPortability.text(1e300) == "1e+300")
    #expect(SettingsPortability.text(Double.infinity) == "inf")
    #expect(SettingsPortability.text(Double.nan) == "nan")
    #expect(SettingsPortability.text([1]) == nil)
  }

  @Test("panes have their titles, symbols and ids")
  func paneMetadata() {
    for pane in ServerSettingsPane.allCases {
      #expect(!pane.title.isEmpty)
      #expect(!pane.systemImage.isEmpty)
      #expect(pane.id == pane)
    }
    #expect(
      Set(ServerSettingsPane.allCases.map(\.title)).count == ServerSettingsPane.allCases.count)
  }

  @Test("each panel default reads back, and an unknown stored value is the default")
  func interfaceDefaults() throws {
    let store = try #require(UserDefaults(suiteName: "settings-logic-\(UUID())"))
    #expect(WorkspacePanelDefault.stored(in: store) == .collapsed)
    store.set("open", forKey: InterfacePreferences.workspacePanelKey)
    #expect(WorkspacePanelDefault.stored(in: store) == .open)
    store.set("sideways", forKey: InterfacePreferences.workspacePanelKey)
    #expect(WorkspacePanelDefault.stored(in: store) == .collapsed)
    #expect(WorkspacePanelDefault.open.showsPanel(isSheet: false))
    #expect(!WorkspacePanelDefault.open.showsPanel(isSheet: true))
    #expect(!WorkspacePanelDefault.collapsed.showsPanel(isSheet: false))
    #expect(WorkspacePanelDefault.allCases.map(\.title) == ["Open", "Collapsed"])

    #expect(DefaultWorkspaceTab.stored(in: store) == .files)
    store.set("github", forKey: InterfacePreferences.defaultWorkspaceTabKey)
    #expect(DefaultWorkspaceTab.stored(in: store) == .github)
    #expect(DefaultWorkspaceTab.github.inspectorTab == .pullRequests)
    #expect(DefaultWorkspaceTab.subagents.inspectorTab == .agents)
    #expect(DefaultWorkspaceTab.changes.inspectorTab == .changes)
    #expect(DefaultWorkspaceTab.files.title == InspectorTab.files.title)

    #expect(!InterfacePreferences.read("missing", defaults: store))
    store.set(true, forKey: "present")
    #expect(InterfacePreferences.read("present", defaults: store))
    #expect(TranscriptViewDefault.allCases.map(\.title) == ["Chat", "Terminal"])
  }

  @Test("the two open-settings actions are equal only for the same presenter, and call it")
  @MainActor
  func presenters() {
    let first = SettingsScreenPresenter()
    var opened = 0
    first.open = { opened += 1 }
    let action = OpenSettingsScreenAction(presenter: first)
    #expect(action == OpenSettingsScreenAction(presenter: first))
    #expect(action != OpenSettingsScreenAction(presenter: SettingsScreenPresenter()))
    action()
    #expect(opened == 1)

    let second = NotificationSettingsPresenter()
    second.open = { opened += 10 }
    let notifications = OpenNotificationSettingsAction(presenter: second)
    #expect(notifications == OpenNotificationSettingsAction(presenter: second))
    #expect(
      notifications != OpenNotificationSettingsAction(presenter: NotificationSettingsPresenter()))
    notifications()
    #expect(opened == 11)
    #expect(SettingsDevice.name == "Mac")
  }
}
