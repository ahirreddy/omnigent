import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTerminalStores
import OmnigentTerminalUI
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI

/// One open conversation on screen: `ConversationScreen` (header, transcript or the harness
/// terminal, decision dock, composer, and the right panel with Files and Changes) over a
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

  @State private var showsInspector = false
  @State private var mode: SessionViewMode = .chat
  @State private var isStopping = false
  @State private var dismissedSendError: CoreError?
  @State private var failures: [String] = []
  @State private var showsTerminals = false
  @State private var harnessSurface: TerminalSurfaceController?

  var body: some View {
    let composer = conversation.composer
    ConversationScreen(
      state: state, composer: composerState,
      draft: Binding(get: { composer.text }, set: { composer.text = $0 }),
      showsInspector: $showsInspector, mode: $mode, actions: actions,
      composerActions: composerActions,
      extras: ConversationExtras(slots: workspaceSlots, navigation: navigation)
    ) {
      harnessTerminal
    }
    .toolbar {
      if terminals != nil {
        ToolbarItem(placement: .primaryAction) {
          Button("Terminals", systemImage: "apple.terminal") { showsTerminals = true }
            .help("Show this session's terminals")
            .accessibilityIdentifier("toolbar.terminals")
        }
      }
    }
    .sheet(isPresented: $showsTerminals) {
      if let terminals {
        TerminalsSheet(
          store: terminals, permissionLevel: conversation.header?.permissionLevel,
          hostID: conversation.header?.settings?.hostId
        ) { showsTerminals = false }
      }
    }
    .sheet(isPresented: documentPresented) {
      if let workspace {
        WorkspaceDocumentSheet(model: workspace) { workspace.close() }
      }
    }
    .alert(
      "Something Went Wrong", isPresented: .constant(!failures.isEmpty),
      actions: { Button("OK") { failures = [] } },
      message: { Text(failures.joined(separator: "\n")) })
    .task { await composer.loadConfiguration() }
    .onChange(of: terminals?.terminals.harness, initial: true) { attachHarness() }
    .onChange(of: changedFilesRevision) {
      guard let workspace else { return }
      Task { await workspace.changedFilesInvalidated() }
    }
  }

  private var state: ConversationViewState {
    var state = ConversationAdapter.state(conversation, summary: summary)
    if let terminals { state.terminal = TerminalAdapter.status(terminals.terminals.harness) }
    return state
  }

  private var composerState: ComposerViewState {
    var state = ComposerAdapter.state(
      conversation, isStopping: isStopping, dismissedError: dismissedSendError)
    if conversation.composer.configuration != nil {
      state.configuration = ComposerAdapter.configuration(conversation.composer)
    }
    return state
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

  /// The right panel's Files and Changes tabs, over the core's workspace reads.
  private var workspaceSlots: WorkspaceSlots {
    guard let workspace else { return WorkspaceSlots() }
    return WorkspaceSlots(
      files: AnyView(WorkspacePanel(model: workspace)),
      changes: AnyView(
        ChangedFilesList(
          model: workspace.changes, source: workspace.source, actions: .none
        ) { file in
          Task { await workspace.open(.diff(path: file.path)) }
        }))
  }

  private var documentPresented: Binding<Bool> {
    let workspace = workspace
    return Binding(
      get: { workspace?.document != nil }, set: { if !$0 { workspace?.close() } })
  }

  private var actions: ConversationActions {
    let conversation = conversation
    let opener = opener
    return ConversationActions(
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
      retry: retry)
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
        Task { await composer.send() }
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
      })
  }

  /// Switches the harness when the core allows it; otherwise says why.
  private func switchHarness(to agentID: String) {
    let composer = conversation.composer
    if let reason = composer.harnessOptions.first(where: { $0.id == agentID })?.unavailableReason
    {
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
