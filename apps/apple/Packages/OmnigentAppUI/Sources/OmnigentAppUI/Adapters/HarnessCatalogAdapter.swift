import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The harness page's MCP servers, Skills and Plugins tabs and its skill page, from the core's
/// reads, worded as the web's `HarnessCatalog`.
enum HarnessCatalogAdapter {
  /// Whether `detail`'s page shows the tabs: a Claude, Codex, Cursor or Pi harness that is
  /// ready, or that the user can set up from here.
  static func offersCatalog(_ detail: HarnessDetail) -> Bool {
    offersCatalog(harness: detail.harness, ready: detail.ready, canFix: detail.canFix)
  }

  static func offersCatalog(harness: String, ready: Bool, canFix: Bool) -> Bool {
    harnessInventoryFamily(harness: harness) != nil && (ready || canFix)
  }

  /// The tabs' state; `nil` where the page lists none.
  static func catalog(_ load: CreationLoad<HarnessInventoryRecord>?, detail: HarnessDetail)
    -> HarnessCatalogState?
  {
    catalog(
      load, harness: detail.harness, ready: detail.ready, canFix: detail.canFix,
      host: detail.hostName)
  }

  /// The tabs' state for `harness` on `host`; `nil` where the page lists none.
  static func catalog(
    _ load: CreationLoad<HarnessInventoryRecord>?, harness: String, ready: Bool, canFix: Bool,
    host: String
  ) -> HarnessCatalogState? {
    guard offersCatalog(harness: harness, ready: ready, canFix: canFix) else { return nil }
    var state = HarnessCatalogState()
    state.firstTab = ready ? .mcpServers : .settings
    guard let read = load?.value else {
      if case .failed = load {
        state.serversNotice = "Couldn\u{2019}t load MCP servers from \(host)."
        state.skillsNotice = "Couldn\u{2019}t load skills from \(host)."
        state.pluginsNotice = "Couldn\u{2019}t load plugins from \(host)."
      } else {
        state.isLoading = true
        state.serversNotice = "Loading MCP servers\u{2026}"
        state.skillsNotice = "Loading skills\u{2026}"
        state.pluginsNotice = "Loading plugins\u{2026}"
      }
      return state
    }
    let opens = harnessInventoryFamily(harness: harness).map(harnessSkillPagesOpen) ?? false
    state.servers = read.mcpServers.map(server)
    state.skills = read.skills.map { skill($0, opens: opens) }
    state.plugins = read.plugins.map { plugin($0, host: host, opens: opens) }
    state.serversNotice = notice(
      read.mcpRead, noun: "MCP servers", empty: state.servers.isEmpty, host: host)
    state.skillsNotice = notice(
      read.skillsRead, noun: "skills", empty: state.skills.isEmpty, host: host)
    state.pluginsNotice = notice(
      read.pluginsRead, noun: "plugins", empty: state.plugins.isEmpty, host: host)
    return state
  }

  private static func notice(
    _ read: InventoryReadState, noun: String, empty: Bool, host: String
  ) -> String? {
    switch read {
    case .unsupported where noun == "MCP servers":
      return "Please update host \(host) to list MCP servers."
    case .failed, .unsupported:
      return "Couldn\u{2019}t load \(noun) from \(host)."
    case .loaded:
      return empty ? "No \(noun) found on \(host)." : nil
    }
  }

  private static func server(_ row: InventoryMcpServer) -> HarnessCatalogState.Server {
    HarnessCatalogState.Server(id: row.id, title: row.title, detail: row.detail, isOff: row.isOff)
  }

  private static func skill(_ row: InventorySkill, opens: Bool) -> HarnessCatalogState.Skill {
    HarnessCatalogState.Skill(
      name: row.name, title: row.title, description: row.description, sourceID: row.sourceId,
      opens: opens)
  }

  private static func plugin(_ row: InventoryPlugin, host: String, opens: Bool)
    -> HarnessCatalogState.Plugin
  {
    let host = { (text: String?) in text?.replacingOccurrences(of: "{host}", with: host) }
    return HarnessCatalogState.Plugin(
      id: row.id, name: row.name, detail: row.detail, description: row.description,
      skills: row.skills.map { skill($0, opens: opens && row.skillsNotice == nil) },
      servers: row.mcpServers.map(server), skillsNotice: host(row.skillsNotice),
      serversNotice: host(row.mcpNotice))
  }

  /// The open skill's page: loading, its contents, or why it can't show.
  static func skillPage(
    _ skill: HarnessCatalogState.Skill, load: CreationLoad<SkillContentRecord>?, host: String
  ) -> HarnessSkillPageState {
    let plugin = skill.name.split(separator: ":", maxSplits: 1).first.map(String.init)
    let back = skill.name.contains(":") ? plugin ?? "Skills" : "Skills"
    var page = HarnessSkillPageState(name: skill.name, backTitle: back)
    switch load {
    case .loaded(let content):
      page.description = content.description
      page.content = content.content
      page.truncated = content.truncated
    case .failed(let error):
      page.notice =
        error.message.contains("HTTP 501")
        ? "Update \(host) to see skill contents." : "Couldn\u{2019}t load skill contents."
    case .idle, .loading, nil:
      page.notice = "Loading skill contents\u{2026}"
    }
    return page
  }
}
