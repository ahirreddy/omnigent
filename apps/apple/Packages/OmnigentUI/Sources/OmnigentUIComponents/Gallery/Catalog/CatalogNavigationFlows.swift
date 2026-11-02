import SwiftUI

/// Flows between surfaces: Inbox triage, the command palette and tabs.
enum NavigationFlowCatalog {
  static var entries: [CatalogEntry] {
    [
      .flow(
        .inbox, "triage", "Inbox Triage",
        summary: "Work through requests with J, K and E without opening each session.",
        systemImage: "tray.full", keywords: ["j k e", "keyboard", "triage"],
        script: triage, live: { _ in AnyView(NavigationStack { InboxTriagePlayground() }) }),
      .flow(
        .palette, "palette-jump", "Command-K to a Session",
        summary: "Open the palette, filter, and jump straight to another session.",
        systemImage: "command", keywords: ["cmd k", "jump", "search"],
        script: paletteJump,
        live: { context in AnyView(CatalogScenarioPage(.palette, context: context)) }),
      .flow(
        .tabs, "tabs", "Tabs: Open, Close, Reopen",
        summary: "Open a terminal, a browser and a side chat in tabs, close one and reopen it.",
        systemImage: "square.on.square", canvas: .largeScreen,
        keywords: ["terminal", "browser", "side chat", "reopen"],
        script: tabs, live: { _ in AnyView(TabsPlayground()) }),
    ]
  }

  typealias Step<Model> = CatalogFlowScript<Model>.Step

  // MARK: Inbox triage

  static var triage: CatalogFlowScript<InboxViewState> {
    CatalogFlowScript(
      initial: { _ in InboxTriageSamples.state },
      steps: [
        Step(
          "open", "Open the Inbox",
          note: "Three requests in two sessions. J and K move, E acts, Return opens."),
        Step(
          "approve", "E: approve the command", note: "The first request is answered in place."
        ) { state in
          TriageSteps.respond(&state, at: 0, .approve)
        },
        Step(
          "answer", "J, E: answer the question", note: "The question's first answer is chosen."
        ) { state in
          TriageSteps.respond(&state, at: 2, .answer(value: "Keep it between runs"))
        },
        Step("read", "E: mark the update read", note: "Updates have no request; E marks them read.")
        { state in
          if state.items.indices.contains(1) { state.items[1].isUnread = false }
        },
        Step(
          "failed", "E fails: the host is offline",
          note: "Nothing is resolved; the request stays answerable.", branchesFrom: "open"
        ) { state in
          state.items[0].phase = .failed(message: "The host is offline. Reconnect and try again.")
        },
      ],
      render: { state, _ in AnyView(TriageFlowScreen(state: state)) })
  }

  // MARK: Palette

  static var paletteJump: CatalogFlowScript<PaletteFlowModel> {
    CatalogFlowScript(
      initial: { context in PaletteFlowModel(context: context) },
      steps: [
        Step("conversation", "In a session", note: "Any screen; Command-K works everywhere."),
        Step("open", "Command-K", note: "Commands first, then sessions and servers.") { model in
          model.isOpen = true
        },
        Step(
          "type", "Type to filter", note: "Matching sessions and commands, best first."
        ) { model in
          model.query = "flaky"
        },
        Step(
          "jump", "Return opens it", note: "The palette closes on the chosen session."
        ) { model in
          model.jump(to: "sess_a2")
        },
      ],
      render: { model, context in AnyView(PaletteFlowScreen(model: model, screen: context.screen)) }
    )
  }

  // MARK: Tabs

  static var tabs: CatalogFlowScript<TabsPlaygroundModel> {
    CatalogFlowScript(
      initial: { _ in TabSamples.flowStart },
      steps: [
        Step("one", "One chat tab", note: "A session in its own tab."),
        Step(
          "terminal", "Open a terminal", note: "Command-T, then Terminal on the new-tab page."
        ) { model in
          model.newTab()
          model.replaceSelected(.terminal, "zsh \u{2014} client-core")
        },
        Step(
          "browser", "Open a browser", note: "A web page in a tab beside the session."
        ) { model in
          model.newTab()
          model.replaceSelected(.browser, "Omnigent Docs")
        },
        Step(
          "side-chat", "Open a side chat", note: "Ask a side question without derailing."
        ) { model in
          model.newTab()
          model.replaceSelected(.sideChat, "Why does the refresh test flake?")
        },
        Step(
          "remote", "Open a remote browser", note: "A browser running on the session's host."
        ) { model in
          model.newTab()
          model.replaceSelected(.remoteBrowser, "example.com")
        },
        Step("close", "Close the browser", note: "Command-W closes the selected tab.") { model in
          if let browser = model.tabs.first(where: { $0.kind == .browser }) {
            model.close(browser.id)
          }
        },
        Step("reopen", "Reopen it", note: "Shift-Command-T reopens the last closed tab.") { model in
          model.reopen()
        },
      ],
      render: { model, context in
        AnyView(CatalogTabsShell(model: model.wrappedValue, screen: context.screen))
      })
  }
}

enum TriageSteps {
  /// Answers the request at `index` as the Inbox's E (or its buttons) would.
  static func respond(_ state: inout InboxViewState, at index: Int, _ response: DecisionResponse) {
    guard state.items.indices.contains(index) else { return }
    state.items[index].phase = .answered(summary: response.summary)
    state.items[index].isUnread = false
    state.needsYouCount = InboxTriageSamples.sessionsNeedingYou(state.items)
  }
}

private struct TriageFlowScreen: View {
  @Binding var state: InboxViewState

  var body: some View {
    NavigationStack {
      InboxView(
        state: state,
        actions: InboxActions(
          open: { _ in },
          markRead: { item in
            if let index = state.items.firstIndex(where: { $0.id == item.id }) {
              state.items[index].isUnread = false
            }
          },
          respond: { card, response in
            if let index = state.items.firstIndex(where: { $0.decision?.id == card.id }) {
              TriageSteps.respond(&state, at: index, response)
            }
          }))
    }
  }
}

/// The palette flow's state: a playground shell, whether the palette is open and its query.
struct PaletteFlowModel {
  let page: PlaygroundModel
  var isOpen = false
  var query = ""

  init(context: CatalogContext) {
    page = PlaygroundModel(scenario: .streaming, preferences: context.preferences)
  }

  /// The palette's entries for the query, as its own search ranks them.
  var results: (commands: [PaletteEntry], state: PaletteViewState) {
    let state = page.paletteState
    let commands = PaletteCatalog.entries(
      state: state,
      commands: SessionCommandActions(focusComposer: {}, toggleViewMode: {}, openChanges: {}))
    guard !query.isEmpty else { return (commands, state) }
    return (
      PaletteSearch.results(commands, query: query),
      PaletteViewState(
        scope: state.scope, sessions: PaletteSearch.results(state.sessions, query: query),
        servers: PaletteSearch.results(state.servers, query: query),
        hasNextRequest: state.hasNextRequest)
    )
  }

  /// Opens `id` through the palette's own action and shows that session.
  mutating func jump(to id: String) {
    page.paletteActions.perform(.session(id))
    if let session = page.sidebar.list.sessions.first(where: { $0.id == id }) {
      page.conversation.header = SessionHeader(
        id: id, title: session.title,
        status: session.status == .needsResponse ? .needsResponse : .idle)
      page.conversation.decisions = [PreviewData.request(PreviewData.codexCommand, in: id)]
      page.conversation.revision += 1
    }
    isOpen = false
    query = ""
  }
}

private struct PaletteFlowScreen: View {
  @Binding var model: PaletteFlowModel
  let screen: CatalogScreen

  var body: some View {
    CatalogShell(model: model.page, screen: screen)
      .overlay {
        if model.isOpen {
          let results = model.results
          CatalogSheetOverlay {
            CommandPalette(state: results.state, commands: results.commands) { target in
              if case .session(let id) = target { model.jump(to: id) }
            }
            .frame(maxWidth: 640, maxHeight: 540)
            .background(.regularMaterial)
          }
        }
      }
  }
}

extension TabSamples {
  /// One chat tab, for the tabs flow.
  static var flowStart: TabsPlaygroundModel {
    let model = TabsPlaygroundModel()
    model.tabs = [TabsPlaygroundModel.chatTab]
    model.selectedID = TabsPlaygroundModel.chatTab.id
    return model
  }
}

/// The shell with its tab strip drawn in place of the titlebar (a nested canvas has no window
/// toolbar), and the selected tab's content.
struct CatalogTabsShell: View {
  @Bindable var model: TabsPlaygroundModel
  let screen: CatalogScreen
  @State private var selection: SidebarDestination?
  @State private var search = ""

  var body: some View {
    HStack(spacing: 0) {
      if screen.showsSidebar {
        NavigationStack {
          SidebarView(
            state: PreviewData.sidebar, selection: $selection, searchText: $search,
            actions: CatalogActions.sidebar)
        }
        .frame(width: 272)
        Divider()
      }
      VStack(spacing: 0) {
        TabStrip(state: model.state, actions: model.actions)
          .padding(.horizontal, Theme.Spacing.small)
          .frame(height: 44)
          .background(.bar)
        Divider()
        CatalogTabContent(model: model)
      }
    }
    .onChange(of: selection) { _, destination in
      if case .session(let id) = destination { model.openChat(id) }
    }
  }
}

/// The selected tab's content, built from the public tab surfaces.
private struct CatalogTabContent: View {
  let model: TabsPlaygroundModel
  @Environment(\.remoteBrowserPreview) private var remoteBrowser

  var body: some View {
    if let tab = model.state.selected {
      Group {
        switch tab.kind {
        case .chat:
          GalleryConversation(
            state: PreviewData.shellConversation, composer: PreviewData.sessionComposer)
        case .terminal, .agentTerminal:
          TerminalSample(title: tab.title)
        case .sideChat:
          SideChatTabView(
            state: SideChatTabState(
              phase: TabSamples.sideChatLoaded,
              sessionTitle: "Refactor token refresh and add tests"),
            openConversation: { model.openChat(PreviewData.sessionID) })
        case .browser, .agentBrowser:
          BrowserSample(tab: tab)
        case .remoteBrowser:
          if let remoteBrowser { remoteBrowser } else { BrowserSample(tab: tab) }
        case .newTab, .newSession, .inbox, .canvas:
          NewTabPage(
            state: NewTabPageState(
              recentSessions: Array(PreviewData.sessions.prefix(5)), canOpenBrowser: true,
              terminalNames: TabsPlaygroundModel.terminalNames),
            actions: NewTabPageActions(
              newTerminal: { _, name in model.replaceSelected(.terminal, name ?? "zsh") },
              openBrowser: { model.replaceSelected(.browser, "Omnigent Docs") },
              openSession: { model.openChat($0) }))
        }
      }
      .id(tab.id)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      NewTabPage(state: NewTabPageState(), actions: CatalogActions.newTab)
    }
  }
}

private struct TerminalSample: View {
  let title: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(
        [
          "~/src/omnigent/client-core main", "$ cargo test -p omnigent-core",
          "running 214 tests", "test refresh::expiry ... ok", "$ \u{2588}",
        ], id: \.self
      ) { Text(verbatim: $0) }
      Spacer(minLength: 0)
    }
    .font(.system(.callout, design: .monospaced))
    .padding(Theme.Spacing.large)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(white: 0.04))
    .environment(\.colorScheme, .dark)
    .accessibilityLabel("Terminal \(title)")
  }
}

private struct BrowserSample: View {
  let tab: TabItemState

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      Text(tab.link?.absoluteString ?? "https://omnigent.ai/docs")
        .font(.callout).foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.extraSmall)
        .background(ThemeColor.hover, in: Capsule())
      Text(tab.title).font(.largeTitle.weight(.semibold))
      Text("Omnigent runs coding agents on your servers and keeps you in the loop.")
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(Theme.Spacing.section)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.background)
  }
}
