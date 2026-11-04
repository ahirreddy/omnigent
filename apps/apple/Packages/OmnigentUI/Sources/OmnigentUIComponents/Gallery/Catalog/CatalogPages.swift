import SwiftUI

/// Whole screens with realistic data, built on the playground's scenarios.
enum PageCatalog {
  static var entries: [CatalogEntry] {
    [
      .page(
        .transcript, "conversation", "Conversation",
        summary: "The session page: transcript, composer, decisions and the right panel.",
        systemImage: "bubble.left.and.text.bubble.right",
        keywords: ["session", "streaming", "approvals", "finished", "terminal"],
        states: [
          scenario("streaming", "Streaming", .streaming),
          scenario("finished", "Finished", .streaming) { PageSamples.finish($0) },
          scenario("approvals", "Approvals waiting", .approvals),
          scenario("subagents", "Sub-agents", .streaming) { model in
            model.conversation = PreviewData.subagentConversation
          },
          scenario("terminal", "Terminal mode", .terminal),
          scenario("errors", "Errors", .errors),
          scenario("inspector", "Right panel open", .streaming) { model in
            model.showsInspector = true
            model.inspectorTab = .changes
          },
          scenario("long", "3,000 rows", .longTranscript),
        ],
        live: { context in AnyView(CatalogScenarioPage(.streaming, context: context)) }),
      .page(
        .newSession, "new-session", "New Session",
        summary: "\u{201C}What should we work on?\u{201D}, in the shell with the session list.",
        systemImage: "plus.bubble", keywords: ["start", "first run", "empty"],
        states: [
          scenario("ready", "Ready", .newSession),
          scenario("first-run", "First run, no sessions", .empty),
        ]),
      .page(
        .inbox, "inbox", "Inbox",
        summary: "The Inbox in the shell: requests needing you across sessions.",
        systemImage: "tray", keywords: ["triage", "needs you"],
        states: [
          scenario("triage", "Triage", .inbox) { model in model.inbox = InboxTriageSamples.state },
          scenario("approvals", "Pending approvals", .approvals) { model in
            model.selection = .inbox
          },
          scenario("caught-up", "All caught up", .inbox) { model in
            model.inbox = InboxSamples.allRead
          },
        ]),
      .page(
        .inbox, "canvas", "Canvas",
        summary: "Every session as a card on one board.",
        systemImage: "rectangle.3.group", canvas: .largeScreen,
        keywords: ["board", "cards"],
        states: [scenario("board", "Board", .streaming) { model in model.selection = .canvas }]),
      .page(
        .palette, "palette", "Command Palette",
        summary: "Command-K over the conversation.",
        systemImage: "command", keywords: ["cmd k", "jump"],
        states: [
          CatalogState("open", "Open") { context in
            AnyView(PaletteOverlayPage(context: context))
          }
        ]),
      .page(
        .tabs, "tabs", "Tabs",
        summary: "The shell with a strip of every tab kind, and the tab overview.",
        systemImage: "square.on.square", canvas: .largeScreen,
        keywords: ["tabs", "overview", "terminal", "browser"],
        states: [
          CatalogState("strip", "Every tab kind") { context in
            AnyView(TabsPage(screen: context.screen, showsOverview: false))
          },
          CatalogState("overview", "Tab overview") { context in
            AnyView(TabsPage(screen: context.screen, showsOverview: true))
          },
        ],
        live: { _ in AnyView(TabsPlayground()) }),
      .page(
        .settings, "settings", "Settings",
        summary: "Server settings and Appearance, as the Settings window shows them.",
        systemImage: "gearshape", canvas: .largeScreen,
        keywords: ["server", "appearance", "theme"],
        states: [
          CatalogState("server", "Server") {
            ServerSettingsView(
              state: PreviewData.serverSettings, selectedServer: .constant("dbx"),
              actions: ServerSettingsActions())
          },
          CatalogState("appearance", "Appearance") { context in
            AnyView(NavigationStack { ThemeSettingsView(preferences: context.preferences) })
          },
        ]),
      .page(
        .decisions, "phone-decisions", "Decisions on iPhone",
        summary: "The dock above the touch composer, and the sheet a substantial request opens.",
        systemImage: "iphone", canvas: .phone, keywords: ["iphone", "sheet", "dock"],
        states: [
          CatalogState("dock", "Dock") { PhoneDecisionPage() },
          CatalogState("sheet", "Request sheet") {
            DecisionSheet(
              state: DecisionSamples.conversation(PreviewData.dockDecisions),
              actions: GalleryActions.conversation, path: .constant([PreviewData.form.id]),
              close: {})
          },
        ],
        live: { _ in AnyView(DecisionPlayground()) }),
      .page(
        .transcript, "phone-reading", "Reading on iPhone",
        summary: "A long running session on iPhone, with a draft kept per session.",
        systemImage: "iphone.gen3", canvas: .phone, keywords: ["iphone", "jump to latest"],
        states: [
          CatalogState("reading", "Reading") {
            GalleryConversation(
              state: PhoneReadingSamples.sessions[0], composer: PreviewData.sessionComposer
            )
            .catalogNavigationBar(PhoneReadingSamples.sessions[0].header.title)
          }
        ],
        live: { _ in AnyView(PhoneReadingPlayground()) }),
    ]
  }

  /// A page from a playground scenario, optionally adjusted after it loads.
  static func scenario(
    _ id: String, _ title: String, _ scenario: PlaygroundScenario,
    configure: @escaping @MainActor (PlaygroundModel) -> Void = { _ in }
  ) -> CatalogState {
    CatalogState(id, title) { context in
      AnyView(CatalogScenarioPage(scenario, context: context, configure: configure))
    }
  }
}

enum PageSamples {
  /// The streaming turn, finished: nothing streams, the session is idle and the composer ready.
  static func finish(_ model: PlaygroundModel) {
    for index in model.conversation.rows.indices {
      model.conversation.rows[index].isStreaming = false
    }
    model.conversation.rows.removeAll { $0.isEphemeral && $0.text.isEmpty }
    model.conversation.header.status = .idle
    model.conversation.revision += 1
    model.composer = PreviewData.idleSessionComposer
  }
}

/// A playground scenario as a page: the full shell on Mac and iPad, the destination in a
/// navigation stack on iPhone.
struct CatalogScenarioPage: View {
  @State private var model: PlaygroundModel
  private let screen: CatalogScreen

  init(
    _ scenario: PlaygroundScenario, context: CatalogContext,
    configure: @MainActor (PlaygroundModel) -> Void = { _ in }
  ) {
    let model = PlaygroundModel(scenario: scenario, preferences: context.preferences)
    configure(model)
    _model = State(initialValue: model)
    screen = context.screen
  }

  var body: some View { CatalogShell(model: model, screen: screen) }
}

/// The shell for a playground model on a screen: the session list beside the destination where
/// the app's split view shows both (Mac, iPad landscape, the unfolded Duo), the destination
/// alone elsewhere. Columns are laid out directly (not in a split view) so captures draw the
/// sidebar, and the right panel is a column so it draws too.
struct CatalogShell: View {
  @Bindable var model: PlaygroundModel
  let screen: CatalogScreen

  var body: some View {
    HStack(spacing: 0) {
      if screen.showsSidebar {
        NavigationStack {
          SidebarView(
            state: model.sidebar, selection: $model.selection, searchText: $model.search,
            actions: model.sidebarActions)
        }
        .frame(width: 272)
        Divider()
      }
      NavigationStack { CatalogDetail(model: model) }
        .catalogNavigationBar(model.navigationTitle)
      if model.showsInspector, model.selection != .newSession, screen.size.width >= 1_100 {
        Divider()
        WorkspaceInspector(
          state: model.conversation, actions: model.conversationActions,
          slots: WorkspaceSlots(), tab: $model.inspectorTab
        )
        .frame(width: 340)
      }
    }
  }
}

/// The destination the playground shell's detail column shows for the model's selection.
private struct CatalogDetail: View {
  @Bindable var model: PlaygroundModel

  /// Import does nothing in the gallery; offering it shows the first-run page.
  private static let importSessions: @MainActor @Sendable () -> Void = {}

  var body: some View {
    switch model.selection {
    case .newSession, nil:
      NewSessionPage(
        draft: $model.startDraft, composer: model.startComposer, actions: model.startActions,
        importSessions: model.sidebar.list.sessions.isEmpty ? Self.importSessions : nil)
    case .inbox:
      InboxView(state: model.inbox, actions: model.inboxActions)
    case .canvas:
      CanvasView(sessions: model.sidebar.list.sessions) { model.selection = .session($0) }
    case .automations:
      AutomationsView(state: PreviewData.automations, actions: AutomationsActions())
    case .usage:
      UsageView(state: PreviewData.usage, actions: UsageActions(formatCost: PreviewData.cost))
    case .session:
      ConversationScreen(
        state: model.conversation, composer: model.composer, draft: $model.draft,
        showsInspector: .constant(false), inspectorTab: $model.inspectorTab,
        mode: $model.mode, fork: $model.fork, actions: model.conversationActions,
        composerActions: model.composerActions,
        extras: ConversationExtras(
          sessionActions: model.sidebarActions.sessions,
          share: (model.share, model.shareActions), forkActions: model.forkActions)
      ) {
        TerminalPlaceholderView(harness: model.conversation.header.settings?.harness)
      }
    }
  }
}

/// A modal drawn in place over a page, so captures show it (a real sheet draws in its own
/// window).
struct CatalogSheetOverlay<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    ZStack {
      Color.black.opacity(0.25).ignoresSafeArea()
      content
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .shadow(radius: 24, y: 8)
        .padding(Theme.Spacing.extraLarge)
    }
  }
}

private struct PaletteOverlayPage: View {
  @State private var model: PlaygroundModel
  private let screen: CatalogScreen

  init(context: CatalogContext) {
    _model = State(
      initialValue: PlaygroundModel(scenario: .streaming, preferences: context.preferences))
    screen = context.screen
  }

  var body: some View {
    CatalogShell(model: model, screen: screen)
      .overlay {
        CatalogSheetOverlay {
          CommandPalette(
            state: model.paletteState,
            commands: PaletteCatalog.entries(
              state: model.paletteState,
              commands: SessionCommandActions(
                focusComposer: {}, toggleViewMode: {}, openChanges: {})),
            perform: { model.paletteActions.perform($0) }
          )
          .frame(maxWidth: 640, maxHeight: 540)
          .background(.regularMaterial)
        }
      }
  }
}

private struct PhoneDecisionPage: View {
  @State private var draft = ""

  var body: some View {
    NavigationStack {
      ConversationScreen(
        state: DecisionSamples.conversation(PreviewData.dockDecisions),
        composer: DecisionSamples.composer, draft: $draft, showsInspector: .constant(false),
        actions: GalleryActions.conversation, composerActions: GalleryActions.composer)
    }
    .catalogNavigationBar(PreviewData.shellConversation.header.title)
  }
}

/// Every tab kind in the shell, optionally with the overview over it.
private struct TabsPage: View {
  let screen: CatalogScreen
  let showsOverview: Bool
  @State private var model = TabsPlaygroundModel()

  var body: some View {
    CatalogTabsShell(model: model, screen: screen)
      .overlay {
        if showsOverview {
          CatalogSheetOverlay {
            TabOverviewSheet(state: model.state, actions: model.actions, dismiss: {})
              .frame(maxWidth: 820, maxHeight: 600)
          }
        }
      }
  }
}
