import OmnigentPlatform
public import SwiftUI

/// Whether a session shows its chat transcript or its harness's terminal (TUI).
nonisolated public enum SessionViewMode: String, Hashable, Sendable, CaseIterable {
  /// The chat transcript and composer.
  case chat
  /// The harness's terminal surface (Claude Code, Codex, Pi and other native harnesses).
  case terminal
}

/// Optional pieces of the conversation screen the host supplies.
public struct ConversationExtras {
  /// Title-menu actions (Pin, Share, Fork, Rename, Mark as unread, Move, Archive, Delete).
  public var sessionActions: SessionListActions
  /// Files and Changes content for the right panel.
  public var slots: WorkspaceSlots
  /// The Share sheet's state and actions; `nil` hides Share.
  public var share: (state: ShareViewState, actions: ShareActions)?
  /// The Fork dialog's actions; the dialog shows while `fork` is non-`nil`.
  public var forkActions: ForkActions?
  /// Previous and next session commands from the host's list.
  public var navigation: SessionCommandActions

  /// Creates extras.
  /// - Parameters:
  ///   - sessionActions: Title-menu actions.
  ///   - slots: Right-panel content.
  ///   - share: Share sheet.
  ///   - forkActions: Fork dialog actions.
  ///   - navigation: Session navigation commands.
  public init(
    sessionActions: SessionListActions = SessionListActions(),
    slots: WorkspaceSlots = WorkspaceSlots(),
    share: (state: ShareViewState, actions: ShareActions)? = nil, forkActions: ForkActions? = nil,
    navigation: SessionCommandActions = SessionCommandActions()
  ) {
    self.sessionActions = sessionActions
    self.slots = slots
    self.share = share
    self.forkActions = forkActions
    self.navigation = navigation
  }
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
  private let terminal: Terminal

  @State private var scrollRequest = 0
  @State private var focusRequest = 0
  @State private var localInspectorTab: InspectorTab = .files
  private let externalInspectorTab: Binding<InspectorTab>?
  @State private var showsShare = false
  @State private var showsInfo = false
  @State private var drafts = DecisionDrafts()
  @State private var approveCandidate: String?
  @State private var commandRelay = FocusedActionsRelay<SessionCommandActions>()
  @Environment(\.layoutWidth) private var layoutWidth
  @Environment(\.transcriptTitleMenu) private var transcriptTitleMenu
  @Environment(\.tabsInTitlebar) private var tabsInTitlebar
  @Environment(\.isActiveTabPane) private var isActivePane
  @Environment(\.offersTerminalView) private var offersTerminalView

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
  ///   - terminal: The terminal surface the app supplies (for example the libghostty view).
  public init(
    state: ConversationViewState, composer: ComposerViewState, draft: Binding<String>,
    showsInspector: Binding<Bool>, inspectorTab: Binding<InspectorTab>? = nil,
    mode: Binding<SessionViewMode>, fork: Binding<ForkViewState?> = .constant(nil),
    actions: ConversationActions, composerActions: ComposerActions,
    extras: ConversationExtras = ConversationExtras(), @ViewBuilder terminal: () -> Terminal
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
        // Inline and sub-agent cards leave Command-Return (and its emphasis) to the dock's card.
        TranscriptView(state: state, actions: actions, scrollToLatestRequest: scrollRequest)
          .decisionApproveShortcut(approveCandidate)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        DecisionDock(state: state, actions: actions)
        if !showsTerminal {
          TranscriptComposer(
            draft: $draft, state: composer, actions: composerActions, focusRequest: focusRequest)
        } else if !state.decisions.isEmpty {
          Spacer().frame(height: 10)
        }
      }
      // Report no minimum width: wrapping banners would otherwise push their single-line
      // ideal width into the split view's minimum and the detail would fail to lay out.
      .frame(minWidth: 0, maxWidth: .infinity)
      // Transcript rows scroll under the dock and composer; never show or click through them.
      .background { BottomBarBackdrop() }
    }
    .themeCanvas()
    .cliPalette()
    .environment(drafts)
    .environment(\.commandReturnOwner, commandReturnOwner)
    .onPreferenceChange(ApproveShortcutCandidate.self) { approveCandidate = $0 }
    .inspector(isPresented: $showsInspector) {
      WorkspaceInspector(state: state, actions: actions, slots: extras.slots, tab: inspectorTab)
        .inspectorColumnWidth(min: 260, ideal: 360, max: 600)
    }
    .navigationTitle(state.header.title)
    // The one status line ("Waiting for you · 2 requests"); the project shows in the sidebar.
    .navigationSubtitle(SessionStatusLine(state).text)
    .toolbarTitleMenu { titleMenu }
    .toolbar { toolbarContent }
    .sheet(isPresented: $showsShare) {
      if let share = extras.share {
        ShareSheet(state: share.state, actions: share.actions) { showsShare = false }
      }
    }
    .sheet(item: ForkSheetID.binding($fork)) { _ in
      if let fork, let forkActions = extras.forkActions {
        ForkSheet(state: fork, actions: forkActions)
      }
    }
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
      // The title menu's commands, Share among them, when the titlebar holds the tabs.
      if tabsInTitlebar {
        SessionActionsButton { titleMenu }
      }
      // At compact width Share lives in the title menu; the top corner is out of thumb reach.
      if extras.share != nil, layoutWidth == .regular, !tabsInTitlebar {
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
      .keyboardShortcut("]", modifiers: [.command, .option])
      .help(
        showsInspector
          ? "Hide the right panel (Option-Command-])" : "Show the right panel (Option-Command-])"
      )
      .accessibilityIdentifier("toggle-inspector")
    }
  }

  @ViewBuilder private var titleMenu: some View {
    if let summary = state.summary {
      let session = extras.sessionActions
      if let setPinned = session.setPinned, summary.canPin {
        Button(
          summary.isPinned ? "Unpin" : "Pin", systemImage: summary.isPinned ? "pin.slash" : "pin"
        ) {
          setPinned(summary, !summary.isPinned)
        }
      }
      if extras.share != nil {
        Button("Share", systemImage: "person.badge.plus") { showsShare = true }
          .disabled(state.shareUnavailableReason != nil)
          .accessibilityIdentifier(tabsInTitlebar ? "header-share" : "title-menu-share")
      }
      if let forkSession = session.fork {
        Button("Fork", systemImage: "arrow.triangle.branch") { forkSession(summary) }
      }
      if let setUnread = session.setUnread {
        Button("Mark as unread", systemImage: "envelope.badge") { setUnread(summary, true) }
      }
      if let setArchived = session.setArchived, summary.canArchive {
        Button(summary.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox") {
          setArchived(summary, !summary.isArchived)
        }
      }
      if let delete = session.delete {
        Button("Delete", systemImage: "trash", role: .destructive) { delete(summary) }
      }
    }
    transcriptTitleMenuItems(transcriptTitleMenu)
    Button("Copy Session ID", systemImage: "number") { Pasteboard.copy(state.header.id) }
  }

  private var canSendDraft: Bool {
    !showsTerminal && composer.availability == .available && composer.delivery == .idle
      && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !composer.attachments.isEmpty)
  }

  /// Send while the draft can go, else the docked request's Approve.
  private var commandReturnOwner: CommandReturnOwner {
    .resolve(canSend: canSendDraft, approvableCardID: approveCandidate)
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
      send: canSend ? composerActions.send : nil,
      interrupt: composer.isRunning ? composerActions.interrupt : nil,
      jumpToLatest: jump, focusComposer: focus,
      toggleInspector: { showsInspector.toggle() },
      previousSession: extras.navigation.previousSession,
      nextSession: extras.navigation.nextSession,
      toggleViewMode: toggleMode,
      openChanges: {
        inspectorTab.wrappedValue = .changes
        showsInspector = true
      })
    actions.approveOwnsCommandReturn = commandReturnOwner == .approve
    return actions
  }
}

extension ConversationScreen where Terminal == EmptyView {
  /// Creates the screen without a terminal mode.
  /// - Parameters:
  ///   - state: The conversation.
  ///   - composer: The composer state.
  ///   - draft: The draft text.
  ///   - showsInspector: Whether the right panel shows.
  ///   - actions: Conversation actions.
  ///   - composerActions: Composer actions.
  ///   - extras: Title menu, right-panel content, Share and navigation.
  public init(
    state: ConversationViewState, composer: ComposerViewState, draft: Binding<String>,
    showsInspector: Binding<Bool>, actions: ConversationActions, composerActions: ComposerActions,
    extras: ConversationExtras = ConversationExtras()
  ) {
    self.init(
      state: state, composer: composer, draft: draft, showsInspector: showsInspector,
      mode: .constant(.chat), actions: actions, composerActions: composerActions, extras: extras
    ) {
      EmptyView()
    }
  }
}

/// The session's actions (Pin, Share, Fork, Archive, Copy Session ID) in the toolbar, where the
/// tabs replace the title and its menu. On the Mac a menu; on iPad a dialog, because a `Menu` in
/// the navigation bar beside the tab strip keeps the bar relaying out (a busy loop on open).
struct SessionActionsButton<Actions: View>: View {
  @ViewBuilder let actions: () -> Actions
  @State private var isPresented = false

  var body: some View {
    #if os(macOS)
      Menu("Session", systemImage: "ellipsis.circle", content: actions)
        .menuIndicator(.hidden)
        .help("Session actions")
        .accessibilityIdentifier("header-session-menu")
    #else
      Button("Session", systemImage: "ellipsis.circle") { isPresented = true }
        .confirmationDialog("Session", isPresented: $isPresented, actions: actions)
        .accessibilityIdentifier("header-session-menu")
    #endif
  }
}

/// The Chat and Terminal segmented switch.
struct ViewModePicker: View {
  @Binding var mode: SessionViewMode
  let status: TerminalStatus

  var body: some View {
    Picker("View", selection: $mode) {
      Label("Chat", systemImage: "bubble.left.and.text.bubble.right").tag(SessionViewMode.chat)
      Label("Terminal", systemImage: "apple.terminal").tag(SessionViewMode.terminal)
    }
    .pickerStyle(.segmented)
    .labelStyle(.iconOnly)
    .fixedSize()
    .help("Chat or Terminal (Option-Command-\\)")
    .accessibilityIdentifier("session-view-mode")
  }
}

private struct HeaderShareLabelStyle: LabelStyle {
  let isCompact: Bool

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      configuration.icon
      if !isCompact { configuration.title }
    }
  }
}

/// The canvas behind the dock and composer, fading in over the transcript's last line.
private struct BottomBarBackdrop: View {
  @Environment(\.omnigentTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Group {
      if let canvas = theme.palette(for: colorScheme).canvas {
        Rectangle().fill(canvas)
      } else {
        Rectangle().fill(.background)
      }
    }
    .mask {
      LinearGradient(
        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08)],
        startPoint: .top, endPoint: .bottom)
    }
    .ignoresSafeArea(edges: .bottom)
    .accessibilityHidden(true)
  }
}
