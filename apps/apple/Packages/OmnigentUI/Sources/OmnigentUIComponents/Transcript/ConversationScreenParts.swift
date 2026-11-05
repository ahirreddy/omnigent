public import SwiftUI

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
  /// The session's projects and sharing, for Move session and the owner-only items.
  public var menuContext: SessionMenuContext
  /// Save the transcript as a file (Export); `nil` hides it.
  public var exportTranscript: (@MainActor () -> Void)?
  /// The Share sheet opened: read the current grants.
  public var shareOpened: (@MainActor () -> Void)?

  /// Creates extras.
  /// - Parameters:
  ///   - sessionActions: Title-menu actions.
  ///   - slots: Right-panel content.
  ///   - share: Share sheet.
  ///   - forkActions: Fork dialog actions.
  ///   - navigation: Session navigation commands.
  ///   - menuContext: Projects and sharing for the session menu.
  ///   - exportTranscript: Export the transcript.
  ///   - shareOpened: The Share sheet opened.
  public init(
    sessionActions: SessionListActions = SessionListActions(),
    slots: WorkspaceSlots = WorkspaceSlots(),
    share: (state: ShareViewState, actions: ShareActions)? = nil, forkActions: ForkActions? = nil,
    navigation: SessionCommandActions = SessionCommandActions(),
    menuContext: SessionMenuContext = SessionMenuContext(),
    exportTranscript: (@MainActor () -> Void)? = nil,
    shareOpened: (@MainActor () -> Void)? = nil
  ) {
    self.sessionActions = sessionActions
    self.slots = slots
    self.share = share
    self.forkActions = forkActions
    self.navigation = navigation
    self.menuContext = menuContext
    self.exportTranscript = exportTranscript
    self.shareOpened = shareOpened
  }
}

/// What the session menu needs beyond the session itself.
nonisolated public struct SessionMenuContext: Hashable, Sendable {
  /// The projects the session can move to.
  public var projects: [SessionProject]
  /// The project it is filed in.
  public var projectID: String?
  /// Shared with the viewer by someone else: Leave instead of Delete, no filing.
  public var isShared: Bool
  /// The session that started this independent worker, as "Created by" links to it.
  public var createdBy: CreatingSession?
  /// The session a sub-agent belongs to, as "Sub-agent of" links to it.
  public var parent: CreatingSession?

  /// Creates a context.
  /// - Parameters:
  ///   - projects: Move targets.
  ///   - projectID: The current project.
  ///   - isShared: Someone else's session.
  ///   - createdBy: The session that started this worker.
  ///   - parent: The session a sub-agent belongs to.
  public init(
    projects: [SessionProject] = [], projectID: String? = nil, isShared: Bool = false,
    createdBy: CreatingSession? = nil, parent: CreatingSession? = nil
  ) {
    self.projects = projects
    self.projectID = projectID
    self.isShared = isShared
    self.createdBy = createdBy
    self.parent = parent
  }

  /// The project the session is filed in.
  public var project: SessionProject? { projects.first { $0.id == projectID } }
}

/// The session that started an independent worker, or a sub-agent's parent.
nonisolated public struct CreatingSession: Hashable, Sendable {
  /// Its id.
  public var id: String
  /// Its title; `nil` when the viewer's list does not have it.
  public var title: String?

  /// Creates a reference.
  /// - Parameters:
  ///   - id: Session id.
  ///   - title: Title, when known.
  public init(id: String, title: String?) {
    self.id = id
    self.title = title
  }
}

/// The session's actions (Pin, Share, Fork, Move session, Archive, Copy Session ID) in the
/// toolbar, where the tabs replace the title and its menu: a menu, so its submenus nest.
struct SessionActionsButton<Actions: View>: View {
  @ViewBuilder let actions: () -> Actions

  var body: some View {
    Menu("Session", systemImage: "ellipsis.circle", content: actions)
      .menuIndicator(.hidden)
      .help("Session actions")
      .accessibilityIdentifier("header-session-menu")
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

struct HeaderShareLabelStyle: LabelStyle {
  let isCompact: Bool

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      configuration.icon
      if !isCompact { configuration.title }
    }
  }
}

/// An invisible backing for the bottom bar that takes the hits its gaps would pass to the
/// transcript beneath; the bar's own controls sit above it and keep theirs.
struct BarHitShield: View {
  var body: some View {
    Color.clear
      .contentShape(Rectangle())
      .accessibilityHidden(true)
  }
}

/// The session menu's Rename prompt and Delete, Leave and Stop confirmations.
struct SessionMenuDialogs: ViewModifier {
  @Binding var renaming: SessionSummary?
  @Binding var renameText: String
  @Binding var confirmingDelete: SessionSummary?
  @Binding var confirmingLeave: SessionSummary?
  @Binding var confirmingStop: SessionSummary?
  let actions: SessionListActions

  func body(content: Content) -> some View {
    content
      .stopSessionConfirmation($confirmingStop, runsOnHost: { _ in false }, stop: actions.stop)
      .sessionRenamePrompt($renaming, text: $renameText, rename: actions.rename)
      .confirmationDialog(
        "Delete this session?",
        isPresented: Binding(
          get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
        presenting: confirmingDelete
      ) { session in
        Button("Delete", role: .destructive) { actions.delete?(session) }
      } message: { _ in
        Text("This permanently deletes the session and its history.")
      }
      .confirmationDialog(
        "Leave this session?",
        isPresented: Binding(
          get: { confirmingLeave != nil }, set: { if !$0 { confirmingLeave = nil } }),
        presenting: confirmingLeave
      ) { session in
        Button("Leave", role: .destructive) { actions.leave?(session) }
      } message: { _ in
        Text("You lose access until someone shares it with you again.")
      }
  }
}

extension ConversationScreen {
  /// Creates the screen over a draft binding, for previews and the gallery whose draft is view
  /// state. The app passes a ``ComposerDraft`` so typing does not re-render the screen.
  public init(
    state: ConversationViewState, composer: ComposerViewState, draft: Binding<String>,
    showsInspector: Binding<Bool>, inspectorTab: Binding<InspectorTab>? = nil,
    mode: Binding<SessionViewMode>, fork: Binding<ForkViewState?> = .constant(nil),
    actions: ConversationActions, composerActions: ComposerActions,
    extras: ConversationExtras = ConversationExtras(), liveRows: LiveTranscriptRows? = nil,
    @ViewBuilder terminal: () -> Terminal
  ) {
    self.init(
      state: state, composer: composer, draft: ComposerDraft(draft),
      showsInspector: showsInspector, inspectorTab: inspectorTab, mode: mode, fork: fork,
      actions: actions, composerActions: composerActions, extras: extras, liveRows: liveRows,
      terminal: terminal)
  }

  /// ⌘Return sends the draft; with messages queued it sends them all now, the draft joining
  /// them at the end (the composer's ⇧⌘Return when ⌘Return is the send chord).
  var sendCommand: @MainActor () -> Void {
    let extras = composerActions.extras
    guard !composer.submitWithCommandReturn, !composer.queue.isEmpty,
      let sendAll = extras.history.sendAllQueued, let queueDraft = extras.queueDraft
    else { return composerActions.send }
    return {
      queueDraft()
      sendAll()
    }
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
