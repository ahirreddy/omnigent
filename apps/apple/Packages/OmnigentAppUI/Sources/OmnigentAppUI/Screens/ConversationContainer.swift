import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTerminalStores
import OmnigentTerminalUI
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI
import UniformTypeIdentifiers

/// One open conversation on screen: `ConversationScreen` (header, transcript or the harness
/// terminal, decision dock, composer, and the right panel with Files, Changes and Terminals) over a
/// ``ConversationStore``. Send, interrupt, decisions and the model, effort and harness menus go
/// through the stores; everything they report, including failures, is rendered.
struct ConversationContainer: View {
  let conversation: ConversationStore
  let summary: OmnigentCoreFFI.SessionSummary?
  let terminals: TerminalStore?
  let workspace: WorkspaceBrowserModel?
  let changedFilesRevision: Int
  let navigation: SessionCommandActions
  let opener: ExternalURLOpener
  let openSession: @MainActor (String) -> Void
  let retry: @MainActor () -> Void
  /// The connected server, for the composer's execution context.
  var server: OmnigentCoreFFI.ConnectedServer?
  /// Opens the session's terminals and side chats as tabs.
  var tabRoutes: ConversationTabRoutes?
  /// The terminals the agent declares, for New Terminal.
  var terminalNames: DeclaredTerminals = .unknown
  /// The session menu's Pin, Archive and the other row actions, as in the sidebar.
  var sessionActions = SessionListActions()
  /// Creates the fork sheet's store; `nil` hides Fork.
  var makeForkStore: (@MainActor () -> ForkStore?)?
  /// Projects and sharing, for the session menu's Move and owner-only items.
  var menuContext = SessionMenuContext()
  /// Creates the Share sheet's store; `nil` hides Share.
  var makeShareStore: (@MainActor () -> ShareStore?)?

  @State private var showsInspector = false
  @State private var mode: SessionViewMode = .chat
  @State private var isStopping = false
  @State private var dismissedSendError: CoreError?
  @State private var failures: [String] = []
  @State private var harnessSurface: TerminalSurfaceController?
  @State private var forkFlow = ForkFlow()
  @State private var export: TranscriptExport?
  @State private var shareStore: ShareStore?
  @AppStorage(ComposerPreferences.submitWithCommandReturnKey) private var submitWithCommandReturn =
    false

  var body: some View {
    let composer = conversation.composer
    ConversationScreen(
      state: state, composer: composerState,
      draft: Binding(get: { composer.text }, set: { composer.text = $0 }),
      showsInspector: $showsInspector, mode: modeBinding, fork: forkSheet,
      actions: routed(forkable(actions)), composerActions: composerActions,
      extras: ConversationExtras(
        sessionActions: forkable(sessionActions), slots: workspaceSlots,
        share: share, forkActions: forkActions, navigation: navigation,
        menuContext: menuContext, exportTranscript: exportTranscript,
        shareOpened: { [shareStore] in Task { await shareStore?.load() } }),
      liveRows: ConversationAdapter.liveRows(conversation)
    ) {
      harnessTerminal
    }
    .sheet(isPresented: documentPresented) {
      if let workspace {
        WorkspaceDocumentSheet(model: workspace) { workspace.close() }
      }
    }
    .fileExporter(
      isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
      document: export, contentType: TranscriptExport.contentType,
      defaultFilename: "\(conversation.sessionID).jsonl"
    ) { result in
      if case .failure(let error) = result {
        failures.append("Could not save the transcript: \(error.localizedDescription)")
      }
    }
    .alert(
      "Something Went Wrong", isPresented: .constant(!failures.isEmpty),
      actions: { Button("OK") { failures = [] } },
      message: { Text(failures.joined(separator: "\n")) }
    )
    .task {
      if shareStore == nil { shareStore = makeShareStore?() }
      composer.searchMentions = workspace.map(Self.mentionSearch)
      await composer.loadConfiguration()
      if let agentID = composer.configuration?.agentId {
        await conversation.loadAgentInfo(agentID: agentID)
      }
      await composer.loadSkills()
    }
    .onChange(of: conversation.isRunning) { _, running in
      Task { await composer.drainQueue(isRunning: running) }
    }
    .onChange(of: terminals?.terminals.harness, initial: true) { attachHarness() }
    .onChange(of: changedFilesRevision) {
      guard let workspace else { return }
      Task { await workspace.changedFilesInvalidated() }
    }
  }

  private var state: ConversationViewState {
    var state = ConversationAdapter.screenState(conversation, summary: summary)
    if let terminals { state.terminal = TerminalAdapter.status(terminals.terminals.harness) }
    state.agentInfo = conversation.agentInfo.map {
      OmnigentUIComponents.AgentInfo(name: $0.name, tools: $0.tools, policies: $0.policies)
    }
    return state
  }

  private var composerState: ComposerViewState {
    ComposerAdapter.state(
      conversation, isStopping: isStopping, dismissedError: dismissedSendError, server: server,
      submitWithCommandReturn: submitWithCommandReturn)
  }

  /// The Share sheet over the session's grants, once its store exists.
  private var share: (state: ShareViewState, actions: ShareActions)? {
    guard let shareStore else { return nil }
    let link = SidebarAdapter.webURL(server: server, sessionID: conversation.sessionID)
    return (ShareAdapter.state(shareStore, link: link), ShareAdapter.actions(shareStore))
  }

  /// Reads the whole transcript, then asks where to save it.
  private func exportTranscript() {
    let conversation = conversation
    Task {
      do throws(CoreError) {
        export = TranscriptExport(text: try await conversation.exportTranscript())
      } catch {
        failures.append("Could not export the transcript: \(error.message)")
      }
    }
  }

  /// Attaches the harness TUI once the core reports it ready. The store keeps the surface, so
  /// switching between Chat and Terminal keeps the screen and scrollback.
  private func attachHarness() {
    guard let terminals else { return }
    harnessSurface = terminals.harnessController(
      permissionLevel: conversation.header?.permissionLevel,
      hostID: conversation.header?.settings?.hostId)
  }

  /// The harness TUI when the core reports it ready, else the package's placeholder.
  @ViewBuilder private var harnessTerminal: some View {
    if let harnessSurface {
      SessionTerminalView(controller: harnessSurface)
    } else {
      VStack {
        TerminalPlaceholderView(harness: conversation.header?.settings?.harness)
        if let terminals, let error = terminals.lastError {
          Label(String(describing: error), systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
    }
  }

  /// The right panel's Files and Changes tabs, over the core's workspace reads, and its
  /// Terminals tab over the session's terminal store.
  private var workspaceSlots: WorkspaceSlots {
    var slots = WorkspaceSlots()
    if let terminals, let tabRoutes {
      var openHarness: (@MainActor () -> Void)?
      if case .ready = terminals.terminals.harness { openHarness = tabRoutes.openHarness }
      slots.terminals = AnyView(
        TerminalsPanel(
          store: terminals, permissionLevel: conversation.header?.permissionLevel,
          openTerminal: tabRoutes.openTerminal, openHarness: openHarness,
          declaredNames: terminalNames))
    }
    guard let workspace else { return slots }
    slots.files = AnyView(WorkspacePanel(model: workspace))
    slots.changes = AnyView(
      ChangedFilesList(
        model: workspace.changes, source: workspace.source, actions: .none
      ) { file in
        Task { await workspace.open(.diff(path: file.path)) }
      })
    return slots
  }

  /// With tabs, choosing Terminal opens the agent's TUI in its own tab and this tab stays on
  /// the chat.
  private var modeBinding: Binding<SessionViewMode> {
    guard let tabRoutes else { return $mode }
    return Binding(
      get: { .chat }, set: { if $0 == .terminal { tabRoutes.openHarness() } })
  }

  /// Side questions open in their own tab; sub-agents and the "Back to the parent session"
  /// capsule open or focus their session's chat tab next to this one.
  private func routed(_ actions: ConversationActions) -> ConversationActions {
    var actions = actions
    if let tabRoutes {
      actions.openSideChat = { row in
        tabRoutes.openSideChat(row.id, row.activity?.detail("question"))
      }
      actions.openChild = tabRoutes.openSession
      actions.openSession = tabRoutes.openSession
    }
    return actions
  }

  /// The session's forkable summary, when this app can fork it.
  private var forkSource: OmnigentCoreFFI.SessionSummary? {
    guard makeForkStore != nil, let summary, forkUnavailableReason(source: summary) == nil else {
      return nil
    }
    return summary
  }

  /// "Fork chat from here" on settled assistant messages.
  private func forkable(_ actions: ConversationActions) -> ConversationActions {
    var actions = actions
    if let source = forkSource {
      actions.forkFrom = { row in
        guard let responseID = ForkAdapter.forkPoint(row) else { return }
        beginFork(
          ForkContext(source: source, upToResponseID: responseID, kind: .fromMessage(rowID: row.id))
        )
      }
    }
    return actions
  }

  /// The session menu's Fork copies the whole session.
  private func forkable(_ actions: SessionListActions) -> SessionListActions {
    var actions = actions
    if let source = forkSource {
      actions.fork = { _ in
        beginFork(ForkContext(source: source, upToResponseID: nil, kind: .session))
      }
    }
    return actions
  }

  private func beginFork(_ context: ForkContext) {
    guard let makeForkStore else { return }
    Task { await forkFlow.begin(context, makeStore: makeForkStore) }
  }

  private var forkSheet: Binding<ForkViewState?> {
    let flow = forkFlow
    return Binding(get: { flow.viewState }, set: { if $0 == nil { flow.cancel() } })
  }

  /// The fork opens as a chat tab next to this one, focused.
  private var forkActions: ForkActions {
    let flow = forkFlow
    let open = tabRoutes?.openSession ?? openSession
    return ForkActions(
      fork: { agentID, directory, start in
        Task {
          await flow.fork(
            agentID: agentID, directory: directory, start: start, open: open,
            report: { failures.append($0) })
        }
      },
      cancel: { flow.cancel() })
  }

  private var documentPresented: Binding<Bool> {
    let workspace = workspace
    return Binding(
      get: { workspace?.document != nil }, set: { if !$0 { workspace?.close() } })
  }
}

extension ConversationContainer {
  private var actions: ConversationActions {
    let conversation = conversation
    let opener = opener
    var actions = ConversationActions(
      openSession: openSession,
      openAttachment: { attachment in
        guard let reference = attachment.reference, let url = URL(string: reference) else {
          return
        }
        open(url, with: opener)
      },
      openURL: { url in open(url, with: opener) },
      respond: { card, response in
        guard let original = conversation.decisions.cards.first(where: { $0.id == card.id })
        else { return }
        Task {
          await conversation.decisions.resolve(
            original, with: OmnigentCoreFFI.DecisionResponse(response))
        }
      },
      dismissError: { conversation.dismissErrors() },
      retry: retry,
      resume: { Task { await conversation.recoverTurn(.resume) } })
    let link = SidebarAdapter.webURL(server: server, sessionID: conversation.sessionID)
    actions.messageURL = { row in Self.messageURL(row, in: link) }
    actions.retryFailedTurn = { row in
      guard let recovery = row.activity?.recovery else { return }
      guard !conversation.isRunning else {
        failures.append("Wait for the current turn to finish before retrying.")
        return
      }
      Task { await conversation.recoverTurn(recovery == .continue ? .continue : .resume) }
    }
    return actions
  }

  private func open(_ url: URL, with opener: ExternalURLOpener) {
    Task {
      if !(await opener.open(url)) { failures.append("Could not open \(url.absoluteString).") }
    }
  }

  private var composerActions: ComposerActions {
    let conversation = conversation
    let composer = conversation.composer
    return ComposerActions(
      send: {
        dismissedSendError = nil
        let newSession = sessionActions.newSession
        Task {
          if await composer.send() == .newSession { newSession?() }
        }
      },
      interrupt: {
        isStopping = true
        Task {
          await conversation.interrupt()
          isStopping = false
        }
      },
      addAttachments: { inputs in
        Task {
          let unreadable = await ComposerAdapter.add(inputs, to: composer)
          failures += unreadable
        }
      },
      removeAttachment: { attachment in
        guard let id = UInt64(attachment.id) else { return }
        composer.removeAttachment(id)
      },
      selectModel: { model in Task { await composer.selectModel(model) } },
      selectEffort: { effort in Task { await composer.selectEffort(effort) } },
      selectAgent: { agentID in switchHarness(to: agentID) },
      acknowledgeUncertainDelivery: { composer.acknowledgeUncertainSend() },
      dismissDeliveryError: {
        dismissedSendError = composer.lastError
        composer.dismissConfigurationError()
      },
      extras: ComposerAdapter.extras(
        composer, isRunning: { conversation.isRunning },
        recallPrevious: { ComposerAdapter.lastPrompt(conversation) }, reconnect: retry))
  }

  /// Switches the harness when the core allows it; otherwise says why.
  private func switchHarness(to agentID: String) {
    let composer = conversation.composer
    if let reason = composer.harnessOptions.first(where: { $0.id == agentID })?.unavailableReason {
      failures.append(reason)
      return
    }
    Task { await composer.switchHarness(to: agentID) }
  }
}

/// An opened workspace file or diff, over the conversation.
private struct WorkspaceDocumentSheet: View {
  let model: WorkspaceBrowserModel
  let close: () -> Void

  var body: some View {
    NavigationStack {
      WorkspaceDocumentView(model: model)
        .navigationTitle(model.document.map(Self.title) ?? "File")
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done", action: close)
          }
        }
    }
    #if os(macOS)
      .frame(minWidth: 720, minHeight: 520)
    #endif
  }

  private static func title(_ document: WorkspaceDocument) -> String {
    switch document {
    case .file(let path, _), .diff(let path): path
    }
  }
}
