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
  let state: ConversationViewState
  let composer: ComposerViewState
  private let draft: ComposerDraft
  @Binding private var showsInspector: Bool
  @Binding private var mode: SessionViewMode
  @Binding private var fork: ForkViewState?
  private let actions: ConversationActions
  let composerActions: ComposerActions
  let extras: ConversationExtras
  private let liveRows: LiveTranscriptRows?
  private let terminal: Terminal

  @State private var scrollRequest = 0
  @State private var focusRequest = 0
  @State private var draftPresence = DraftPresence()
  @State private var modelPickerRequest = 0
  @State private var localInspectorTab: InspectorTab = .files
  private let externalInspectorTab: Binding<InspectorTab>?
  /// The session the Rename Session command is renaming.
  @State private var renaming: SessionSummary?
  @State private var renameText = ""
  @State private var drafts = DecisionDrafts()
  @State private var approveCandidate: DecisionShortcutTarget?
  @State private var decisionSurfaces = DecisionSurfaces()
  @State private var commandRelay = FocusedActionsRelay<SessionCommandActions>()
  @Environment(\.offersTerminalView) private var offersTerminalView

  /// Creates the screen.
  /// - Parameters:
  ///   - state: The conversation.
  ///   - composer: The composer state.
  ///   - draft: The draft text, read only by the composer.
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
    state: ConversationViewState, composer: ComposerViewState, draft: ComposerDraft,
    showsInspector: Binding<Bool>, inspectorTab: Binding<InspectorTab>? = nil,
    mode: Binding<SessionViewMode>, fork: Binding<ForkViewState?> = .constant(nil),
    actions: ConversationActions, composerActions: ComposerActions,
    extras: ConversationExtras = ConversationExtras(), liveRows: LiveTranscriptRows? = nil,
    @ViewBuilder terminal: () -> Terminal
  ) {
    self.state = state
    self.composer = composer
    self.draft = draft
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

  /// Only a chat whose harness has a terminal offers the terminal view; other tabs do not.
  private var offersTerminal: Bool { state.terminalAvailable && offersTerminalView }

  private var inspectorTab: Binding<InspectorTab> { externalInspectorTab ?? $localInspectorTab }

  /// The screen.
  public var body: some View {
    ZStack {
      // A request answers inline while its card is on screen, else in the dock. The transcript
      // stays built under the terminal, so going back to Chat shows it where it was.
      LiveTranscript(
        state: state, liveRows: liveRows, actions: transcriptActions,
        scrollToLatestRequest: scrollRequest
      )
      .modifier(InlineApproveShortcut(target: approveCandidate))
      .chatDropTarget(
        isEnabled: composerState.acceptsAttachments && composerState.availability == .available,
        add: composerActions.addAttachments
      )
      .modifier(HiddenUnderTerminal(showsTerminal: showsTerminal))
      // A hidden tab lets go of the terminal surface, as a terminal tab does.
      if showsTerminal {
        ShownTabOnly { TerminalPane(status: state.terminal, resume: actions.resume) { terminal } }
      }
    }
    .countsRenders("screen")
    // A bar: the transcript fades under the dock and composer, its inset following them.
    .safeAreaBar(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        // Under the terminal no card is on screen, so every request answers in the dock.
        DecisionDock(state: state, actions: actions)
          .environment(showsTerminal ? nil : decisionSurfaces)
        if !showsTerminal {
          TranscriptComposer(
            draft: draft, state: composerState, actions: composerActions,
            focusRequest: focusRequest
          ) { [draftPresence] in draftPresence.report($0) }
        } else if !state.decisions.isEmpty {
          Spacer().frame(height: 10)
        }
      }
      // No minimum width: wrapping banners would push their ideal width into the split view's.
      .frame(minWidth: 0, maxWidth: .infinity)
      // Clicks and taps in the bar's gaps stop here instead of reaching the rows beneath.
      .background { BarHitShield() }
    }
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .safeAreaInset(edge: .top, spacing: 0) {
      if let open = actions.openSession {
        if let sourceID = state.sideChatSourceID {
          let parent = extras.menuContext.parent
          SessionOriginBar(
            relation: .sideChatOf,
            origin: CreatingSession(
              id: sourceID, title: parent?.id == sourceID ? parent?.title : nil),
            open: open)
        } else if let parentID = state.parentSessionID {
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
    .modifier(CommandReturnOwnership(arbitration: commandReturn))
    .onPreferenceChange(ApproveShortcutCandidate.self) { approveCandidate = $0 }
    // The toolbar controls and the right panel, unless the window shows its session's.
    .modifier(OwnSessionChrome(chrome: chrome))
    .sheet(item: ForkSheetID.binding($fork)) { _ in
      if let fork, let forkActions = extras.forkActions {
        ForkSheet(state: fork, actions: forkActions)
      }
    }
    .sessionRenamePrompt($renaming, text: $renameText, rename: extras.sessionActions.rename)
    // In a split window only the focused pane's conversation drives the menus.
    .modifier(
      ActivePaneCommands(commands: commands, commandReturn: commandReturn, relay: commandRelay))
  }

  /// The toolbar controls and the right panel, over this conversation.
  private var chrome: SessionChrome {
    SessionChrome(
      state: state, extras: extras, actions: actions, mode: $mode,
      showsInspector: $showsInspector, inspectorTab: inspectorTab, fork: $fork)
  }
}

extension ConversationScreen {
  /// Who answers Command-Return, resolved where it is used: the draft gaining or losing its
  /// text reaches Send and Approve without running this screen's body.
  private var commandReturn: CommandReturnArbitration {
    CommandReturnArbitration(
      presence: draftPresence,
      sendIsOpen: !showsTerminal && composer.availability == .available
        && composer.delivery.acceptsSend(canQueue: composerActions.extras.queueDraft != nil),
      hasAttachedContent: !composer.attachments.isEmpty || !composer.mentions.isEmpty,
      approvableCardID: approveCandidate?.cardID)
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
      send: sendCommand,
      interrupt: composer.isRunning ? composerActions.interrupt : nil,
      jumpToLatest: jump, focusComposer: focus,
      toggleInspector: extras.togglePanel ?? { showsInspector.toggle() },
      previousSession: extras.navigation.previousSession,
      nextSession: extras.navigation.nextSession,
      toggleViewMode: toggleMode,
      openChanges: { chrome.showPanel(.changes) })
    if chat, let configuration = composer.configuration, configuration.acceptsChanges {
      addModelCommands(to: &actions, configuration: configuration)
    }
    if let summary = state.summary, summary.canRename, extras.sessionActions.rename != nil {
      actions.rename = {
        renameText = summary.title
        renaming = summary
      }
    }
    actions.addNestedAgent = chrome.addNestedAgentCommand
    return actions
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
