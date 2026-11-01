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
  @State private var inspectorTab: InspectorTab = .files
  @State private var showsShare = false
  @State private var showsInfo = false
  @State private var drafts = DecisionDrafts()
  @Environment(\.layoutWidth) private var layoutWidth

  /// Creates the screen.
  /// - Parameters:
  ///   - state: The conversation.
  ///   - composer: The composer state.
  ///   - draft: The draft text.
  ///   - showsInspector: Whether the right panel shows.
  ///   - mode: Chat or Terminal.
  ///   - fork: The Fork dialog's state; non-`nil` shows it.
  ///   - actions: Conversation actions.
  ///   - composerActions: Composer actions.
  ///   - extras: Title menu, right-panel content, Share and navigation.
  ///   - terminal: The terminal surface the app supplies (for example the libghostty view).
  public init(
    state: ConversationViewState, composer: ComposerViewState, draft: Binding<String>,
    showsInspector: Binding<Bool>, mode: Binding<SessionViewMode>,
    fork: Binding<ForkViewState?> = .constant(nil), actions: ConversationActions,
    composerActions: ComposerActions, extras: ConversationExtras = ConversationExtras(),
    @ViewBuilder terminal: () -> Terminal
  ) {
    self.state = state
    self.composer = composer
    _draft = draft
    _showsInspector = showsInspector
    _mode = mode
    _fork = fork
    self.actions = actions
    self.composerActions = composerActions
    self.extras = extras
    self.terminal = terminal()
  }

  private var showsTerminal: Bool { mode == .terminal && state.terminalAvailable }

  /// The screen.
  public var body: some View {
    Group {
      if showsTerminal {
        TerminalPane(status: state.terminal, resume: actions.resume) { terminal }
      } else {
        TranscriptView(state: state, actions: actions, scrollToLatestRequest: scrollRequest)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        DecisionDock(state: state, actions: actions)
        if !showsTerminal {
          ComposerView(
            draft: $draft, state: composer, actions: composerActions, focusRequest: focusRequest)
        } else if !state.decisions.isEmpty {
          Spacer().frame(height: 10)
        }
      }
      // Report no minimum width: wrapping banners would otherwise push their single-line
      // ideal width into the split view's minimum and the detail would fail to lay out.
      .frame(minWidth: 0, maxWidth: .infinity)
    }
    .themeCanvas()
    .environment(drafts)
    .inspector(isPresented: $showsInspector) {
      WorkspaceInspector(state: state, actions: actions, slots: extras.slots, tab: $inspectorTab)
        .inspectorColumnWidth(min: 240, ideal: 420, max: 600)
    }
    .navigationTitle(state.header.title)
    #if os(macOS)
      .navigationSubtitle(state.projectName ?? "")
    #endif
    .toolbarTitleMenu { titleMenu }
    .toolbar { toolbarContent }
    .sheet(isPresented: $showsShare) {
      if let share = extras.share {
        ShareSheet(state: share.state, actions: share.actions) { showsShare = false }
      }
    }
    .sheet(item: $fork) { fork in
      if let forkActions = extras.forkActions {
        ForkSheet(state: fork, actions: forkActions)
      }
    }
    .focusedSceneValue(\.sessionCommands, commands)
  }

  @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
    if state.terminalAvailable {
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
      }
      if extras.share != nil {
        Button {
          showsShare = true
        } label: {
          Label("Share", systemImage: "person.badge.plus")
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
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
    Button("Copy Session ID", systemImage: "number") { Pasteboard.copy(state.header.id) }
  }

  private var commands: SessionCommandActions {
    let chat = !showsTerminal
    let canSend =
      chat && composer.availability == .available && composer.delivery == .idle
      && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !composer.attachments.isEmpty)
    var jump: (@MainActor () -> Void)?
    var focus: (@MainActor () -> Void)?
    if chat {
      jump = { scrollRequest += 1 }
      focus = { focusRequest += 1 }
    }
    var toggleMode: (@MainActor () -> Void)?
    if state.terminalAvailable {
      let binding = $mode
      toggleMode = { binding.wrappedValue = binding.wrappedValue == .chat ? .terminal : .chat }
    }
    return SessionCommandActions(
      send: canSend ? composerActions.send : nil,
      interrupt: composer.isRunning ? composerActions.interrupt : nil,
      jumpToLatest: jump, focusComposer: focus,
      toggleInspector: { showsInspector.toggle() },
      previousSession: extras.navigation.previousSession,
      nextSession: extras.navigation.nextSession,
      toggleViewMode: toggleMode)
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
