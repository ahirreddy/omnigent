import Foundation

// Sample data for the web-structured shell: sidebar, session page extras, composer controls,
// the new-session page, the Inbox, Share and Fork.
extension PreviewData {
  // MARK: Sidebar

  static let projects = [
    SessionProject(id: "proj_gitspoke", name: "Gitspoke", sessionIds: ["sess_a2", "sess_y1"]),
    SessionProject(id: "proj_omni", name: "Omni", sessionIds: ["sess_w1"]),
  ]

  static let rowInfo: [String: SessionRowInfo] = [
    sessionID: SessionRowInfo(
      harness: "codex-native", environment: "Ahir's MacBook Pro", repo: "omnigent",
      branch: "auth-refresh"),
    "sess_a2": SessionRowInfo(
      harness: "claude-native", environment: "Managed sandbox", repo: "universe"),
    "sess_a3": SessionRowInfo(harness: "codex-native", environment: "CI runner"),
    "sess_a4": SessionRowInfo(harness: "pi", isShared: true),
    "sess_y1": SessionRowInfo(harness: "codex-native", hasDraft: true),
    "sess_w1": SessionRowInfo(harness: "antigravity", environment: "runner"),
    "sess_m1": SessionRowInfo(harness: "claude-native", isDisconnected: true),
  ]

  static let servers = [
    ServerChoice(
      id: "dbx", name: "ai-devtools-prod", url: "https://ai-devtools.cloud.databricks.com"),
    ServerChoice(id: "local", name: "Local server", url: "http://127.0.0.1:6767"),
    ServerChoice(
      id: "staging", name: "Staging", url: "https://staging.omnigent.dev", isConnected: false),
  ]

  static let sidebar = SidebarViewState(
    list: sessionList, rowInfo: rowInfo, projects: projects, inboxCount: 2, servers: servers,
    currentServerID: "dbx")

  // MARK: Session page

  static let pullRequests = [
    PullRequestSummary(
      id: "pr1", number: 20_001_536, title: "Coalesce token refreshes",
      repo: "omnigent-ai/omnigent",
      url: "https://github.com/omnigent-ai/omnigent/pull/20001536", status: .running),
    PullRequestSummary(
      id: "pr2", number: 19_998_120, title: "Add expiry tests", repo: "omnigent-ai/omnigent",
      url: "https://github.com/omnigent-ai/omnigent/pull/19998120", status: .merged),
  ]

  static let agentInfo = AgentInfo(
    name: "Codex", tools: ["shell", "apply_patch", "web_search", "github"],
    policies: ["No network to package registries", "Ask before pushing"])

  static var timestamps: [String: Date] {
    var result: [String: Date] = [:]
    for (index, row) in rows.enumerated() {
      result[row.id] = now.addingTimeInterval(TimeInterval(-3_600 + index * 90))
    }
    return result
  }

  static var shellConversation: ConversationViewState {
    var state = conversation
    state.timestamps = timestamps
    state.turnDurations = ["resp_1": 106]
    state.summary = sessions.first { $0.id == sessionID }
    state.projectName = "Omni"
    state.pullRequests = pullRequests
    state.agentInfo = agentInfo
    state.terminal = .ready
    state.viewerName = "Ahir"
    return state
  }

  // MARK: Composer

  static let hosts = ComposerHosts(
    hosts: [
      ComposerHost(id: "host_cloud", name: "Databricks sandbox", kind: .cloud, isOnline: true),
      ComposerHost(id: "host_mbp", name: "Ahir's MacBook Pro", kind: .machine, isOnline: true),
      ComposerHost(id: "host_ci", name: "CI runner", kind: .machine, isOnline: false),
    ], selectedID: "host_mbp")

  static let codexModes = ComposerSamples.codexModes()

  static let claudeModes = ComposerSamples.claudeModes()

  static let slashCommands = [
    SlashCommand(name: "review", description: "Review the current changes", isSkill: true),
    SlashCommand(name: "compact", description: "Summarize the conversation"),
    SlashCommand(name: "model", description: "Change the model"),
    SlashCommand(name: "test", description: "Run the test suite", isSkill: true),
  ]

  static let mentionPaths = [
    "client-core/crates/omnigent-core/src/auth/refresh.rs",
    "client-core/crates/omnigent-core/src/auth/tests.rs",
    "apps/apple/README.md",
  ]

  static var sessionComposer: ComposerViewState {
    var state = composerRunning
    state.hosts = ComposerHosts(hosts: hosts.hosts, selectedID: "host_mbp", isLocked: true)
    state.approvalModes = codexModes
    state.tray = ComposerTray(
      directory: "/Users/ahir/src/omnigent", branch: "auth-refresh", pullRequest: "#20001536",
      contextFraction: 0.66)
    state.slashCommands = slashCommands
    state.mentionCandidates = mentionPaths
    state.queue = [QueuedMessage(id: "q1", text: "Also update the changelog when you're done")]
    state.context = ComposerSamples.context
    state.canSteer = true
    return state
  }

  static var idleSessionComposer: ComposerViewState {
    var state = sessionComposer
    state.isRunning = false
    state.queue = []
    state.placeholder = "Send a message\u{2026}"
    return state
  }

  static var startComposer: ComposerViewState {
    ComposerViewState(
      configuration: ComposerConfiguration(
        harness: "claude-native", modelOptions: models, selectedModelId: nil, selectedEffort: nil),
      placeholder: "Describe a task to start a new session\u{2026}", hosts: hosts,
      approvalModes: claudeModes,
      tray: ComposerTray(
        directory: "/Users/ahir/src/universe",
        recentDirectories: ["/Users/ahir/src/universe", "/Users/ahir/src/omnigent"],
        worktree: "No worktree", worktrees: ["auth-refresh", "release-2026.11"]),
      slashCommands: slashCommands, purpose: .start, context: ComposerSamples.start.context)
  }

  // MARK: Inbox

  // One request each for sess_a2 and sess_p1, the two sessions the sidebar counts.
  static var inbox: InboxViewState {
    var state = InboxViewState(
      items: [
        InboxItem(
          id: "in1", kind: .approval, sessionId: "sess_a2",
          sessionTitle: "Fix flaky SSE reconnect test",
          preview: "Run the auth test suite.", date: now.addingTimeInterval(-600),
          decision: request(codexCommand, in: "sess_a2")),
        InboxItem(
          id: "in2", kind: .question, sessionId: "sess_p1", sessionTitle: "Release checklist",
          preview: "Which branch should I push to?", date: now.addingTimeInterval(-5_400),
          decision: request(choice, in: "sess_p1")),
        InboxItem(
          id: "in3", kind: .comment, sessionId: "sess_a4",
          sessionTitle: "Design review: inspector layout",
          preview: "sam.lee: Can we keep the Info tab?", date: now.addingTimeInterval(-90_000)),
        InboxItem(
          id: "in4", kind: .unread, sessionId: "sess_y1",
          sessionTitle: "Port session query to Rust",
          preview: "Done. 24 tests ported.", date: now.addingTimeInterval(-300_000), isUnread: false
        ),
      ], now: now)
    state.needsYouCount = 2
    return state
  }

  // MARK: Share and fork

  static let share = ShareViewState(
    generalAccess: "Restricted", workspaceFiles: true,
    grants: [
      ShareGrant(id: "g1", principal: "ankit@example.com", role: .edit),
      ShareGrant(id: "g2", principal: "sam.lee@example.com", role: .read),
    ], link: URL(string: "https://omnigent.example.com/c/sess_7Hq2"))

  static let fork = ForkViewState(
    id: "fork1", kind: .fromMessage(rowID: "item_a1"), agents: catalog.agents,
    agentID: "agent_codex",
    directory: "/Users/ahir/src/omnigent",
    recentDirectories: ["/Users/ahir/src/omnigent", "/Users/ahir/src/web"])
}

extension PreviewData {
  static var serverSettings: ServerSettingsViewState {
    ServerSettingsViewState(
      servers: servers,
      harnesses: [
        ServerHarness(id: "h1", name: "Claude Code", harness: "claude-native", isEnabled: true),
        ServerHarness(id: "h2", name: "Codex", harness: "codex-native", isEnabled: true),
        ServerHarness(
          id: "h3", name: "Cursor", harness: "cursor-native", isEnabled: false,
          note: "Needs sign-in on 1 host"),
        ServerHarness(id: "h4", name: "Pi", harness: "pi", isEnabled: true),
      ],
      mcpServices: [
        MCPServiceRow(
          id: "m1", name: "GitHub", detail: "Issues and pull requests", isConnected: true,
          tools: ["search", "create_issue"], canDisconnect: true),
        MCPServiceRow(id: "m2", name: "Linear", isConnected: false, connectsInBrowser: true),
      ],
      connections: [
        ProviderConnectionRow(id: "github", name: "GitHub", isConnected: true, account: "ahir"),
        ProviderConnectionRow(id: "databricks", name: "Databricks", isConnected: false),
      ],
      members: [
        ServerMember(
          id: "ahir@example.com", detail: "Last signed in today", isAdmin: true,
          canResetPassword: true),
        ServerMember(
          id: "ankit@example.com", detail: "Never signed in", isAdmin: false,
          canResetPassword: true, canRemove: true),
      ],
      policies: [
        ServerSettingRow(id: "p1", name: "Ask before pushing", detail: "omnigent.policies.ask"),
        ServerSettingRow(
          id: "p2", name: "Limit tool calls", detail: "omnigent.policies.limit", isReadOnly: true),
      ],
      sharing: SharingViewState(
        mode: "on",
        modeChoices: [
          SettingChoice(id: "on", title: "Anyone can share"),
          SettingChoice(id: "off", title: "Sharing off"),
        ],
        modeEditable: true, publicSharing: true, publicSharingEditable: true),
      archived: sessions.filter(\.isPinned),
      importHosts: [SettingChoice(id: "h1", title: "ahir-mbp")],
      importSources: [SettingChoice(id: "all", title: "All harnesses")], isAdmin: true)
  }
}
