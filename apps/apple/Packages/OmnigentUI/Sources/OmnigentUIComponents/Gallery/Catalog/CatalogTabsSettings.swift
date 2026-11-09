import SwiftUI

/// Tabs and the palette: the strip, tab items, the overview, the new-tab page, side chats and
/// the command palette.
enum TabsCatalog {
  static var entries: [CatalogEntry] {
    [
      .component(
        .tabs, "strip", "Tab Strip",
        summary: "The titlebar strip with every tab kind and status, pinned tabs and overflow.",
        systemImage: "square.on.square", canvas: .fixed(width: 1_100, height: 52),
        keywords: ["tabs", "pinned", "overflow"],
        states: [
          strip("every-kind", "Every kind", TabsPlaygroundModel().state),
          strip(
            "one", "One tab", TabsState(tabs: [TabsPlaygroundModel.chatTab], selectedID: "chat")),
          strip("overflow", "Overflow", TabSamples.overflow),
          strip("issue", "Restore issue", TabSamples.issue),
        ],
        live: { _ in AnyView(TabsPlayground()) }),
      .component(
        .tabs, "item", "Tab Item",
        summary: "One tab in every status: needs you, running, failed, loading, activity, unread.",
        systemImage: "rectangle.on.rectangle.angled", canvas: .column(width: 260),
        keywords: ["status", "badge", "audio"],
        states: [CatalogState("statuses", "Every status") { TabItemSample() }]),
      .component(
        .tabs, "overview", "Tab Overview",
        summary: "All tabs as a searchable grid (Show All Tabs).",
        systemImage: "square.grid.3x2", canvas: .fixed(width: 820, height: 600),
        keywords: ["overview", "show all"],
        states: [
          CatalogState("all", "All tabs") {
            TabOverviewSheet(
              state: TabsPlaygroundModel().state, actions: TabActions(), dismiss: {})
          }
        ]),
      .component(
        .tabs, "new-tab", "New Tab Page",
        summary:
          "The launcher a new tab opens on: a side chat, terminal or browser in the session.",
        systemImage: "plus.square.on.square", canvas: .fixed(width: 900, height: 640),
        keywords: ["launcher", "side chat"],
        states: [
          CatalogState("full", "Every launcher") {
            NewTabPage(state: TabsPlaygroundModel.newTabState, actions: CatalogActions.newTab)
          },
          CatalogState("empty", "Nothing to open") {
            NewTabPage(state: NewTabPageState(), actions: NewTabPageActions())
          },
        ]),
      .component(
        .tabs, "side-chat", "Side Chat Tab",
        summary: "A side question opened into its own tab.",
        systemImage: "bubble.left.and.bubble.right", canvas: .fixed(width: 820, height: 560),
        keywords: ["side chat", "question"],
        states: [
          sideChat("loaded", "Answered", TabSamples.sideChatLoaded),
          sideChat(
            "pending", "Waiting for the answer",
            .loaded(question: "Why does the refresh test flake on CI?", answer: nil)),
          sideChat("loading", "Loading", .loading),
          sideChat("unavailable", "Unavailable", .unavailable),
        ]),
      .component(
        .palette, "palette", "Command Palette",
        summary: "Command-K: commands, sessions and servers in one search.",
        systemImage: "command", canvas: .fixed(width: 640, height: 540),
        keywords: ["cmd k", "search", "jump"],
        states: [
          palette(
            "default", "Commands and sessions", PlaygroundModel(scenario: .palette).paletteState),
          palette("no-request", "Nothing waiting", PaletteSamples.nothingWaiting),
          palette("empty", "No sessions", PaletteViewState(scope: "Mac Studio", sessions: [])),
        ]),
      .component(
        .palette, "shortcuts", "Keyboard Shortcuts",
        summary: "The Command-/ sheet listing every shortcut.",
        systemImage: "keyboard", canvas: .fixed(width: 520, height: 640),
        keywords: ["shortcuts", "keys"],
        states: [CatalogState("sheet", "Sheet") { KeyboardShortcutsSheet() }]),
    ]
  }

  private static func strip(_ id: String, _ title: String, _ state: TabsState) -> CatalogState {
    CatalogState(id, title) {
      TabStrip(state: state, actions: TabActions())
        .padding(.horizontal, Theme.Spacing.small)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }
  }

  private static func sideChat(
    _ id: String, _ title: String, _ phase: SideChatTabState.Phase
  ) -> CatalogState {
    CatalogState(id, title) {
      SideChatTabView(
        state: SideChatTabState(phase: phase, sessionTitle: "Refactor token refresh and add tests"),
        openConversation: {})
    }
  }

  private static func palette(_ id: String, _ title: String, _ state: PaletteViewState)
    -> CatalogState
  {
    CatalogState(id, title) {
      CommandPalette(
        state: state,
        commands: PaletteCatalog.entries(
          state: state,
          commands: SessionCommandActions(focusComposer: {}, toggleViewMode: {}, openChanges: {})),
        perform: { _ in })
    }
  }
}

enum TabSamples {
  static var overflow: TabsState {
    var state = TabsPlaygroundModel().state
    let extra = PreviewData.sessions.map {
      TabItemState(id: "extra-\($0.id)", kind: .chat, title: $0.title)
    }
    state.tabs += extra
    return state
  }

  static var issue: TabsState {
    var state = TabsPlaygroundModel().state
    state.issue = "Two tabs could not be restored: their sessions were deleted."
    return state
  }

  static let sideChatLoaded = SideChatTabState.Phase.loaded(
    question: "Why does the refresh test flake on CI?",
    answer: """
      The test waits on a fixed 50 ms timer, but the CI runners are slower. \
      Waiting for the refresh event instead removes the race.
      """)
}

enum PaletteSamples {
  static var nothingWaiting: PaletteViewState {
    let state = PlaygroundModel(scenario: .palette).paletteState
    return PaletteViewState(
      scope: state.scope, sessions: state.sessions, servers: state.servers, hasNextRequest: false)
  }
}

private struct TabItemSample: View {
  private let statuses: [TabStatus] = [
    .none, .needsYou, .running, .failed, .loading, .terminalActivity, .unread, .exited,
  ]

  var body: some View {
    CatalogStack(spacing: Theme.Spacing.small) {
      ForEach(Array(statuses.enumerated()), id: \.offset) { index, status in
        TabItemView(
          tab: TabItemState(
            id: "t\(index)", kind: index.isMultiple(of: 2) ? .chat : .terminal,
            title: "Tab with status \(index)", status: status, isPlayingAudio: index == 4),
          isSelected: index == 0, width: 210, actions: TabActions(), canCloseToRight: false)
      }
    }
  }
}

/// Settings: the server settings panes.
enum SettingsCatalog {
  static var entries: [CatalogEntry] {
    [
      .component(
        .settings, "server", "Server Settings",
        summary: "Harnesses, MCP, Git, Members, Policies, Sharing and Archived, per server.",
        systemImage: "server.rack", canvas: .fixed(width: 900, height: 600),
        keywords: ["settings", "admin", "harness", "mcp"],
        states: [
          settings("admin", "Admin", PreviewData.serverSettings),
          settings("member", "Member (read only)", SettingsSamples.member),
          settings("error", "Load error", SettingsSamples.error),
        ])
    ]
  }

  private static func settings(
    _ id: String, _ title: String, _ state: ServerSettingsViewState
  ) -> CatalogState {
    CatalogState(id, title) {
      ServerSettingsView(
        state: state, selectedServer: .constant("dbx"), actions: ServerSettingsActions())
    }
  }
}

enum SettingsSamples {
  static var member: ServerSettingsViewState {
    var state = PreviewData.serverSettings
    state.isAdmin = false
    return state
  }

  static var error: ServerSettingsViewState {
    var state = PreviewData.serverSettings
    state.errorMessage = "Could not load settings: the server returned 403."
    return state
  }
}

/// New session: the new-session page, the creation sheet and markdown.
enum NewSessionCatalog {
  static var entries: [CatalogEntry] {
    [
      .component(
        .newSession, "page", "New Session Page",
        summary: "\u{201C}What should we build?\u{201D} with the start composer and its tray.",
        systemImage: "plus.bubble", canvas: .fixed(width: 1_000, height: 720),
        keywords: ["start", "landing", "host", "directory"],
        states: [
          startPage("ready", "Ready", ComposerSamples.start),
          startPage("unavailable", "Host offline", ComposerSamples.startUnavailable),
          CatalogState("import", "No sessions yet", note: "Offers importing existing sessions.") {
            NewSessionPage(
              draft: .constant(""), composer: PreviewData.startComposer,
              actions: GalleryActions.composer, importSessions: {})
          },
        ],
        live: { _ in AnyView(NavigationStack { ComposerPlayground() }) }),
      .component(
        .newSession, "sheet", "New Session Sheet",
        summary: "The creation sheet: host, agent, workspace and model, with core validation.",
        systemImage: "plus.square", canvas: .fixed(width: 560, height: 720),
        keywords: ["create", "host", "agent", "workspace"],
        states: [
          sheet("loaded", "Loaded", PreviewData.newSession),
          sheet("loading", "Loading", NewSessionSamples.loading),
          sheet("creating", "Creating", NewSessionSamples.phase(.creating)),
          sheet(
            "failed", "Failed",
            NewSessionSamples.phase(.failed(message: "The host rejected the workspace path."))),
          sheet(
            "uncertain", "Uncertain",
            NewSessionSamples.phase(
              .uncertain(message: "The connection dropped. Check the session list first."))),
        ]),
      .component(
        .markdown, "markdown", "Markdown",
        summary: "The transcript's markdown: headings, lists, tables, quotes and code.",
        systemImage: "textformat", canvas: .column(width: 760),
        keywords: ["table", "code", "list"],
        states: [
          CatalogState("reply", "Assistant reply") {
            CatalogStack { MarkdownView(PreviewData.assistantMarkdown) }
          },
          CatalogState("code", "Long code") {
            CatalogStack {
              CodeBlockView(code: PreviewData.patch, language: "diff")
              CodeBlockView(code: PreviewData.patch, language: "diff", maxLines: 6)
            }
          },
          CatalogState("long", "Long words") {
            CatalogStack { MarkdownView(CatalogSamples.longText) }
          },
        ]),
    ]
  }

  private static func startPage(_ id: String, _ title: String, _ composer: ComposerViewState)
    -> CatalogState
  {
    CatalogState(id, title) {
      NewSessionPage(draft: .constant(""), composer: composer, actions: GalleryActions.composer)
    }
  }

  private static func sheet(_ id: String, _ title: String, _ state: NewSessionViewState)
    -> CatalogState
  {
    CatalogState(id, title) {
      NavigationStack {
        NewSessionView(
          state: state,
          actions: NewSessionActions(
            unavailableReason: PreviewData.unavailableReason, create: { _, _, _ in },
            cancel: {}))
      }
    }
  }
}

enum NewSessionSamples {
  static var loading: NewSessionViewState {
    var state = PreviewData.newSession
    state.catalog = .loading
    state.workspaces = .loading
    state.models = .loading
    return state
  }

  static func phase(_ phase: CreationPhase) -> NewSessionViewState {
    var state = PreviewData.newSession
    state.phase = phase
    return state
  }
}
