import OmnigentPlatform
public import SwiftUI

/// Whether a session shows its chat transcript or its harness's terminal (TUI).
nonisolated public enum SessionViewMode: String, Hashable, Sendable, CaseIterable {
  /// The chat transcript and composer.
  case chat
  /// The harness's terminal surface (Claude Code, Codex, Pi and other native harnesses).
  case terminal
}

/// A whole conversation, laid out like the web's session page: the toolbar header (title menu,
/// viewers, Info, Chat/Terminal, Share, right-panel toggle), the transcript or the harness's
/// terminal on the theme canvas, pending decisions docked above the composer, and the right
/// panel with Files, Changes, Pull Requests, Agents and Info.
public struct ConversationScreen<Terminal: View>: View {
  private let state: ConversationViewState
  private let composer: ComposerViewState
  @Binding private var draft: String
  @Binding private var showsInspector: Bool
  @Binding private var mode: SessionViewMode
  @Binding private var fork: ForkViewState?
  private let actions: ConversationActions
  private let composerActions: ComposerActions
  private let extras: ConversationExtras
  private let liveRows: LiveTranscriptRows?
  private let terminal: Terminal

  @State private var scrollRequest = 0
  @State private var focusRequest = 0
  @State private var modelPickerRequest = 0
  @State private var localInspectorTab: InspectorTab = .files
  private let externalInspectorTab: Binding<InspectorTab>?
  @State private var showsShare = false
  @State private var showsInfo = false
  @State private var renaming: SessionSummary?
  @State private var renameText = ""
  @State private var confirmingDelete: SessionSummary?
  @State private var confirmingLeave: SessionSummary?
  @State private var confirmingStop: SessionSummary?
  @State private var drafts = DecisionDrafts()
  @State private var approveCandidate: DecisionShortcutTarget?
  @State private var decisionSurfaces = DecisionSurfaces()
  @State private var commandRelay = FocusedActionsRelay<SessionCommandActions>()
  @Environment(\.layoutWidth) private var layoutWidth
  @Environment(\.transcriptWindow) private var transcriptWindow
  @Environment(\.openAppearanceSettings) private var openAppearanceSettings
  @Environment(\.tabsInTitlebar) private var tabsInTitlebar
  @Environment(\.isActiveTabPane) private var isActivePane
  @Environment(\.offersTerminalView) private var offersTerminalView
  @Environment(\.isTabContentHidden) private var isHiddenTab

  /// Creates the screen.
  /// - Parameters:
  ///   - state: The conversation.
  ///   - composer: The composer state.
  ///   - draft: The draft text.
  ///   - showsInspector: Whether the right panel shows.
  ///   - inspectorTab: The right panel's tab; `nil` keeps it in the screen (Files first).
  ///   - mode: Chat or Terminal.
  ///   - fork: The Fork dialog's state; non-`nil` shows it.
  ///   - actions: Conversation actions.
  ///   - composerActions: Composer actions.
  ///   - extras: Title menu, right-panel content, Share and navigation.
  ///   - liveRows: Reads the rows inside the transcript, so streaming re-renders only the
  ///     transcript; `nil` uses `state.rows`.
  ///   - terminal: The terminal surface the app supplies (for example the libghostty view).
  public init(
    state: ConversationViewState, composer: ComposerViewState, draft: Binding<String>,
    showsInspector: Binding<Bool>, inspectorTab: Binding<InspectorTab>? = nil,
    mode: Binding<SessionViewMode>, fork: Binding<ForkViewState?> = .constant(nil),
    actions: ConversationActions, composerActions: ComposerActions,
    extras: ConversationExtras = ConversationExtras(), liveRows: LiveTranscriptRows? = nil,
    @ViewBuilder terminal: () -> Terminal
  ) {
    self.state = state
    self.composer = composer
    _draft = draft
    _showsInspector = showsInspector
    externalInspectorTab = inspectorTab
    _mode = mode
    _fork = fork
    self.actions = actions
    self.composerActions = composerActions
    self.extras = extras
    self.liveRows = liveRows
    self.terminal = terminal()
  }

  private var showsTerminal: Bool { mode == .terminal && offersTerminal }

  /// Only a session's primary chat has the terminal view; side chats and other tabs do not.
  private var offersTerminal: Bool { state.terminalAvailable && offersTerminalView }

  private var inspectorTab: Binding<InspectorTab> { externalInspectorTab ?? $localInspectorTab }

  /// The screen.
  public var body: some View {
    Group {
      if showsTerminal {
        TerminalPane(status: state.terminal, resume: actions.resume) { terminal }
      } else {
        // A request answers inline while its card is on screen, else in the dock.
        LiveTranscript(
          state: state, liveRows: liveRows, actions: transcriptActions,
          scrollToLatestRequest: scrollRequest
        )
        .decisionApproveShortcut(approveCandidate, on: .inline, owner: commandReturnOwner)
      }
    }
    // A bar: the transcript fades under the dock and composer, its inset following them.
    .safeAreaBar(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        DecisionDock(state: state, actions: actions)
        if !showsTerminal {
          TranscriptComposer(
            draft: $draft, state: composerState, actions: composerActions,
            focusRequest: focusRequest)
        } else if !state.decisions.isEmpty {
          Spacer().frame(height: 10)
        }
      }
      // No minimum width: wrapping banners would push their ideal width into the split view's.
      .frame(minWidth: 0, maxWidth: .infinity)
      .decisionBottomBar(decisionSurfaces)
      // Clicks and taps in the bar's gaps stop here instead of reaching the rows beneath.
      .background { BarHitShield() }
    }
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .safeAreaInset(edge: .top, spacing: 0) {
      if let open = actions.openSession {
        if let parentID = parentSessionID {
          let parent = extras.menuContext.parent
          SessionOriginBar(
            relation: .subagentOf,
            origin: CreatingSession(
              id: parentID, title: parent?.id == parentID ? parent?.title : nil),
            open: open)
        } else if let creator = extras.menuContext.createdBy {
          SessionOriginBar(relation: .createdBy, origin: creator, open: open)
        }
      }
    }
    .themeCanvas()
    .cliPalette()
    .environment(drafts).environment(decisionSurfaces)
    .environment(\.commandReturnOwner, commandReturnOwner)
    .onPreferenceChange(ApproveShortcutCandidate.self) { approveCandidate = $0 }
    .workspaceInspector(
      state: state, actions: actions, slots: extras.slots,
      isPresented: isHiddenTab ? .constant(false) : $showsInspector, tab: inspectorTab
    )
    .navigationTitle(state.header.title)
    // The one status line ("Waiting for you · 2 requests"); the project shows in the sidebar.
    .navigationSubtitle(SessionStatusLine(state).text)
    .toolbarTitleMenu { titleMenu }
    .preference(key: TitlebarTrailingItems.self, value: isHiddenTab ? nil : trailingItems)
    .toolbar { toolbarContent }
    .sheet(isPresented: $showsShare) {
      if let share = extras.share {
        ShareSheet(state: share.state, actions: share.actions) { showsShare = false }
          .onAppear { extras.shareOpened?() }
      }
    }
    .sheet(item: ForkSheetID.binding($fork)) { _ in
      if let fork, let forkActions = extras.forkActions {
        ForkSheet(state: fork, actions: forkActions)
      }
    }
    .modifier(
      SessionMenuDialogs(
        renaming: $renaming, renameText: $renameText, confirmingDelete: $confirmingDelete,
        confirmingLeave: $confirmingLeave, confirmingStop: $confirmingStop,
        actions: extras.sessionActions)
    )
    // In a split window only the focused pane's conversation drives the menus.
    .focusedSceneValue(\.sessionCommands, commandRelay.publish(isActivePane ? commands : nil))
  }

  @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
    // A split window's other pane leaves the toolbar to the focused one.
    if isActivePane {
      paneToolbar
    }
  }

  @ToolbarContentBuilder private var paneToolbar: some ToolbarContent {
    // With tabs in the titlebar, the agent's TUI is its own tab (Option-Command-\\ opens it).
    if offersTerminal, !tabsInTitlebar {
      ToolbarItem(placement: .principal) {
        ViewModePicker(mode: $mode, status: state.terminal)
      }
    }
    ToolbarItemGroup(placement: .primaryAction) {
      if let presence = state.section("presence"), layoutWidth == .regular {
        ViewerStack(viewers: SectionReading.viewers(presence))
      }
      if let info = state.agentInfo, !(info.tools.isEmpty && info.policies.isEmpty) {
        Button("Agent info", systemImage: "info.circle") { showsInfo.toggle() }
          .popover(isPresented: $showsInfo) { AgentInfoPopover(info: info) }
          .help("Agent info")
          .accessibilityIdentifier("header-agent-info")
      }
      if let summary = state.summary, showsProjectTag,
        let move = extras.sessionActions.moveToProject
      {
        HeaderProjectTag(session: summary, context: extras.menuContext, move: move)
      }
      // The title menu's commands, Share among them, when the titlebar holds the tabs.
      if tabsInTitlebar {
        SessionActionsButton { titleMenu }
      }
      // At compact width Share lives in the title menu; the top corner is out of thumb reach.
      if extras.share != nil, layoutWidth == .regular {
        Button {
          showsShare = true
        } label: {
          Label("Share", systemImage: "person.badge.plus")
            .labelStyle(HeaderShareLabelStyle(isCompact: layoutWidth == .compact))
        }
        .buttonStyle(.bordered)
        .disabled(state.shareUnavailableReason != nil)
        .help(state.shareUnavailableReason ?? "Share this session")
        .accessibilityIdentifier("header-share")
      }
      Button {
        showsInspector.toggle()
      } label: {
        Label("Right panel", systemImage: "sidebar.trailing")
      }
      .keyboardShortcut(AppShortcuts.rightPanel)
      .help(
        showsInspector
          ? "Hide the right panel (Option-Command-])" : "Show the right panel (Option-Command-])"
      )
      .accessibilityIdentifier("toggle-inspector")
    }
  }

  @ViewBuilder private var titleMenu: some View {
    if let summary = state.summary {
      sessionMenu(summary).items
    } else {
      Button("Copy Session ID", systemImage: "number") { Pasteboard.copy(state.header.id) }
    }
    if let exportTranscript = extras.exportTranscript {
      Button("Export\u{2026}", systemImage: "square.and.arrow.down", action: exportTranscript)
        .accessibilityIdentifier("header-export-conversation")
    }
    if let open = actions.openSession {
      if let parentID = parentSessionID {
        Button("Go to Parent Session", systemImage: "chevron.backward") { open(parentID) }
      }
      if let creator = extras.menuContext.createdBy {
        Button("Go to Creating Session", systemImage: "arrow.up.backward") { open(creator.id) }
      }
    }
    transcriptTitleMenuItems(
      TranscriptTitleMenu(window: transcriptWindow, openAppearance: openAppearanceSettings))
  }

  /// The sidebar row's menu for this session (as the web's header menu mirrors its row), with
  /// Share opening this screen's sheet.
  private func sessionMenu(_ summary: SessionSummary) -> SessionRowMenu {
    var actions = extras.sessionActions
    actions.share = nil
    if extras.share != nil, state.shareUnavailableReason == nil {
      let present: @MainActor (SessionSummary) -> Void = { _ in showsShare = true }
      actions.share = present
    }
    let context = extras.menuContext
    return SessionRowMenu(
      session: summary, isUnread: false, isShared: context.isShared, pinLimitReached: false,
      projects: context.projects, actions: actions,
      rename: {
        renameText = summary.title
        renaming = summary
      },
      confirmDelete: { confirmingDelete = summary },
      confirmLeave: { confirmingLeave = summary },
      confirmStop: { confirmingStop = summary },
      project: context.projects.first { $0.id == context.projectID })
  }
}

extension ConversationScreen {
  /// A sub-agent's parent session.
  private var parentSessionID: String? {
    state.header.settings?.parentId.flatMap { $0.isEmpty || $0 == state.header.id ? nil : $0 }
  }

  /// The header's project tag: the viewer's own top-level session.
  private var showsProjectTag: Bool {
    state.summary != nil
      && HeaderProjectTag.applies(
        extras.menuContext, isSubagent: parentSessionID != nil,
        canMove: extras.sessionActions.moveToProject != nil)
  }

  private var canSendDraft: Bool {
    !showsTerminal && composer.availability == .available && composer.delivery == .idle
      && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !composer.attachments.isEmpty || !composer.mentions.isEmpty)
  }

  private var trailingItems: Int {
    TitlebarTrailingItems.count(
      state, hasShare: extras.share != nil, tabsInTitlebar: tabsInTitlebar,
      isRegular: layoutWidth == .regular)
      + (showsProjectTag ? 1 : 0)
  }

  /// Send while the draft can go, else the active request's Approve.
  private var commandReturnOwner: CommandReturnOwner {
    .resolve(canSend: canSendDraft, approvableCardID: approveCandidate?.cardID)
  }

  /// A reply to selected text lands in the composer, focused for typing.
  private var transcriptActions: ConversationActions {
    var actions = actions
    if let reply = actions.replyWithSelection {
      actions.replyWithSelection = { text in
        reply(text)
        focusRequest += 1
      }
    }
    return actions
  }

  private var commands: SessionCommandActions {
    let chat = !showsTerminal
    let canSend = canSendDraft
    var jump: (@MainActor () -> Void)?
    var focus: (@MainActor () -> Void)?
    if chat {
      jump = { scrollRequest += 1 }
      focus = { focusRequest += 1 }
    }
    var toggleMode: (@MainActor () -> Void)?
    if offersTerminal {
      let binding = $mode
      toggleMode = { binding.wrappedValue = binding.wrappedValue == .chat ? .terminal : .chat }
    }
    var actions = SessionCommandActions(
      send: canSend ? sendCommand : nil,
      interrupt: composer.isRunning ? composerActions.interrupt : nil,
      jumpToLatest: jump, focusComposer: focus,
      toggleInspector: { showsInspector.toggle() },
      previousSession: extras.navigation.previousSession,
      nextSession: extras.navigation.nextSession,
      toggleViewMode: toggleMode,
      openChanges: {
        inspectorTab.wrappedValue = .changes
        extras.slots.documents?.showPanel()
        showsInspector = true
      })
    actions.approveOwnsCommandReturn = commandReturnOwner == .approve
    if chat, let configuration = composer.configuration, !configuration.isApplying {
      addModelCommands(to: &actions, configuration: configuration)
    }
    if let summary = state.summary, summary.canRename, extras.sessionActions.rename != nil {
      actions.rename = {
        renameText = summary.title
        renaming = summary
      }
    }
    return actions
  }

  /// ⌘Return sends the draft; with messages queued it sends them all now, the draft joining
  /// them at the end (the composer's ⇧⌘Return when ⌘Return is the send chord).
  private var sendCommand: @MainActor () -> Void {
    let extras = composerActions.extras
    guard !composer.submitWithCommandReturn, !composer.queue.isEmpty,
      let sendAll = extras.history.sendAllQueued, let queueDraft = extras.queueDraft
    else { return composerActions.send }
    return {
      queueDraft()
      sendAll()
    }
  }

  /// The composer with this screen's picker requests.
  private var composerState: ComposerViewState {
    var state = composer
    state.modelPickerRequest = modelPickerRequest
    return state
  }

  /// Choose Model, Next Model and Next Reasoning Effort, where the session offers them.
  private func addModelCommands(
    to actions: inout SessionCommandActions, configuration: ComposerConfiguration
  ) {
    if let selectModel = composerActions.selectModel, !configuration.visibleModels.isEmpty {
      actions.chooseModel = { modelPickerRequest += 1 }
      if let next = configuration.nextModelID { actions.cycleModel = { selectModel(next) } }
    }
    if let selectEffort = composerActions.selectEffort, let next = configuration.nextEffort {
      actions.cycleEffort = { selectEffort(next) }
    }
  }
}
