import Foundation

/// A harness's MCP servers, skills and plugins on a host, as its Settings page's tabs list them
/// (the web's `HarnessCatalog`).
public struct HarnessCatalogState: Equatable, Sendable {
  /// The page's tabs, in order.
  public enum Tab: String, CaseIterable, Identifiable, Sendable {
    /// MCP servers.
    case mcpServers
    /// Skills.
    case skills
    /// Plugins.
    case plugins
    /// The credential and startup configuration.
    case settings

    /// The tab itself.
    public var id: Self { self }

    /// The label before its count.
    public var title: String {
      switch self {
      case .mcpServers: "MCP servers"
      case .skills: "Skills"
      case .plugins: "Plugins"
      case .settings: "Settings"
      }
    }
  }

  /// An MCP server.
  public struct Server: Equatable, Sendable, Identifiable {
    /// A stable id.
    public var id: String
    /// Its name.
    public var title: String
    /// Its plugin and URL host.
    public var detail: String?
    /// Turned off for Omnigent sessions.
    public var isOff: Bool

    /// Creates a server.
    public init(id: String, title: String, detail: String? = nil, isOff: Bool = false) {
      self.id = id
      self.title = title
      self.detail = detail
      self.isOff = isOff
    }
  }

  /// A skill; it opens its page when `opens`.
  public struct Skill: Equatable, Sendable, Identifiable {
    /// The name its page asks for.
    public var name: String
    /// The name it shows.
    public var title: String
    /// What it does.
    public var description: String
    /// A plugin skill's id.
    public var sourceID: String?
    /// Its page can open.
    public var opens: Bool

    /// The name, as the row's identity.
    public var id: String { name }

    /// Creates a skill.
    public init(
      name: String, title: String, description: String = "", sourceID: String? = nil,
      opens: Bool = false
    ) {
      self.name = name
      self.title = title
      self.description = description
      self.sourceID = sourceID
      self.opens = opens
    }
  }

  /// A plugin, with its page's lists.
  public struct Plugin: Equatable, Sendable, Identifiable {
    /// A stable id.
    public var id: String
    /// Its name.
    public var name: String
    /// Version, marketplace, state and counts.
    public var detail: String
    /// What it does.
    public var description: String?
    /// Its skills.
    public var skills: [Skill]
    /// Its MCP servers.
    public var servers: [Server]
    /// Why its skills can't be read here.
    public var skillsNotice: String?
    /// Why its MCP servers can't be inspected.
    public var serversNotice: String?

    /// Creates a plugin.
    public init(
      id: String, name: String, detail: String, description: String? = nil,
      skills: [Skill] = [], servers: [Server] = [], skillsNotice: String? = nil,
      serversNotice: String? = nil
    ) {
      self.id = id
      self.name = name
      self.detail = detail
      self.description = description
      self.skills = skills
      self.servers = servers
      self.skillsNotice = skillsNotice
      self.serversNotice = serversNotice
    }
  }

  /// MCP servers.
  public var servers: [Server] = []
  /// Skills no plugin ships.
  public var skills: [Skill] = []
  /// Plugins.
  public var plugins: [Plugin] = []
  /// What shows instead of the servers: loading, a failure or none; `nil` lists them.
  public var serversNotice: String?
  /// What shows instead of the skills.
  public var skillsNotice: String?
  /// What shows instead of the plugins.
  public var pluginsNotice: String?
  /// The lists are being read, so the tabs show no counts.
  public var isLoading = false
  /// The tab that opens first: MCP servers for a ready harness, else Settings.
  public var firstTab: Tab = .mcpServers

  /// Creates the state.
  public init() {}

  /// A tab's label: `MCP servers · 2` once read, the bare label while reading.
  public func label(_ tab: Tab) -> String {
    let count: Int? =
      switch tab {
      case .mcpServers: servers.count
      case .skills: skills.count
      case .plugins: plugins.count
      case .settings: nil
      }
    guard let count, !isLoading else { return tab.title }
    return "\(tab.title) \u{00B7} \(count)"
  }
}

/// A skill's page: its description and `SKILL.md`, rendered as Markdown.
public struct HarnessSkillPageState: Equatable, Sendable {
  /// The name asked for: `review`, or `toolkit:lint`.
  public var name: String
  /// Back to the list it came from: "Skills", or the plugin's name.
  public var backTitle: String
  /// What it does.
  public var description: String
  /// Its contents.
  public var content: String
  /// Cut at the host's 256 KiB limit.
  public var truncated: Bool
  /// Loading or why it can't show; `nil` shows the contents.
  public var notice: String?

  /// Creates a page.
  public init(
    name: String, backTitle: String, description: String = "", content: String = "",
    truncated: Bool = false, notice: String? = nil
  ) {
    self.name = name
    self.backTitle = backTitle
    self.description = description
    self.content = content
    self.truncated = truncated
    self.notice = notice
  }
}
