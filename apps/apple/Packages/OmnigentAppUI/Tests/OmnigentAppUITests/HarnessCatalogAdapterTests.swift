import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// The harness page's MCP servers, Skills and Plugins tabs, worded as the web's catalog.
@Suite("Harness catalog adapter")
struct HarnessCatalogAdapterTests {
  private func record(
    mcp: InventoryReadState = .loaded, skills: InventoryReadState = .loaded
  ) -> HarnessInventoryRecord {
    HarnessInventoryRecord(
      mcpServers: [
        InventoryMcpServer(id: "claude:github", title: "GitHub", detail: nil, isOff: true)
      ],
      skills: [
        InventorySkill(name: "review", title: "review", description: "Review", sourceId: nil)
      ],
      plugins: [
        InventoryPlugin(
          id: "p1", name: "toolkit", detail: "1 skill \u{00B7} 0 MCPs", description: nil,
          skills: [
            InventorySkill(name: "toolkit:lint", title: "lint", description: "", sourceId: "s1")
          ],
          mcpServers: [], skillsNotice: "Update {host} to read installed plugin skills.",
          mcpNotice: nil)
      ],
      mcpRead: mcp, skillsRead: skills, pluginsRead: .loaded)
  }

  private func catalog(
    _ load: CreationLoad<HarnessInventoryRecord>?, harness: String = "claude-native",
    ready: Bool = true, canFix: Bool = false
  ) -> HarnessCatalogState? {
    HarnessCatalogAdapter.catalog(
      load, harness: harness, ready: ready, canFix: canFix, host: "Mac")
  }

  @Test("A server the host reports a switch for gets one, shown as asked while it saves")
  func omnigentSwitch() throws {
    var switchable = record()
    switchable.mcpServers = [
      InventoryMcpServer(
        id: "claude:github", title: "GitHub", detail: nil, isOff: false, switchHarness: "claude"),
      InventoryMcpServer(
        id: "claude:jira", title: "Jira", detail: nil, isOff: true, switchHarness: "claude",
        switchLocked: true),
      InventoryMcpServer(id: "claude:notes", title: "Notes", detail: nil, isOff: false),
    ]
    let state = try #require(catalog(.loaded(switchable)))
    #expect(
      state.servers.map(\.omnigentSwitch) == [
        HarnessMcpSwitch(isOn: true), HarnessMcpSwitch(isOn: false, isLocked: true), nil,
      ])
    let saving = HarnessCatalogAdapter.switching(
      state, ["h1/claude-native/claude:github": false], prefix: "h1/claude-native/")
    #expect(saving.servers[0].omnigentSwitch == HarnessMcpSwitch(isOn: false, isSaving: true))
    #expect(saving.servers[0].isOff)
    #expect(saving.servers[1] == state.servers[1])
  }

  @Test("Only inventory harnesses that are ready or fixable get the tabs")
  func offered() {
    #expect(catalog(.loading) != nil)
    #expect(catalog(.loading, harness: "gemini-native") == nil)
    #expect(catalog(.loading, ready: false, canFix: false) == nil)
    #expect(catalog(.loading, ready: false, canFix: true)?.firstTab == .settings)
    #expect(catalog(.loading)?.firstTab == .mcpServers)
  }

  @Test("Loading hides the counts; a read shows them, with each list's own notice")
  func labelsAndNotices() throws {
    let loading = try #require(catalog(.loading))
    #expect(loading.label(.mcpServers) == "MCP servers")
    #expect(loading.serversNotice == "Loading MCP servers\u{2026}")

    let loaded = try #require(catalog(.loaded(record())))
    #expect(loaded.label(.mcpServers) == "MCP servers \u{00B7} 1")
    #expect(loaded.label(.settings) == "Settings")
    #expect(loaded.serversNotice == nil && loaded.skillsNotice == nil)
    #expect(loaded.servers.first?.isOff == true)
    #expect(loaded.skills.first?.opens == true)
    let plugin = try #require(loaded.plugins.first)
    #expect(plugin.skillsNotice == "Update Mac to read installed plugin skills.")
    #expect(plugin.skills.first?.opens == false, "an older host's plugin skills don't open")

    let old = try #require(catalog(.loaded(record(mcp: .unsupported, skills: .failed))))
    #expect(old.serversNotice == "Please update host Mac to list MCP servers.")
    #expect(old.skillsNotice == "Couldn\u{2019}t load skills from Mac.")
    let piCatalog = try #require(catalog(.loaded(record()), harness: "pi-native"))
    #expect(piCatalog.skills.first?.opens == false, "Pi's skills have no page")
  }

  @Test("A skill page loads, shows its contents, or says why not")
  func skillPage() {
    let skill = HarnessCatalogState.Skill(name: "toolkit:lint", title: "lint", opens: true)
    let loading = HarnessCatalogAdapter.skillPage(skill, load: .loading, host: "Mac")
    #expect(loading.notice == "Loading skill contents\u{2026}")
    #expect(loading.backTitle == "toolkit")
    let content = SkillContentRecord(
      name: "toolkit:lint", description: "Lint", content: "# Lint", truncated: true)
    let page = HarnessCatalogAdapter.skillPage(skill, load: .loaded(content), host: "Mac")
    #expect(page.notice == nil && page.truncated && page.content == "# Lint")
    let plain = HarnessCatalogState.Skill(name: "review", title: "review")
    #expect(HarnessCatalogAdapter.skillPage(plain, load: nil, host: "Mac").backTitle == "Skills")
  }
}
