import Foundation
public import Observation
public import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
  import AppKit
#endif

/// A sample-data scenario for the playground app and previews.
public enum PlaygroundScenario: String, CaseIterable, Identifiable, Sendable {
  /// A turn streaming in, with tools running.
  case streaming
  /// A native-harness session shown in Terminal mode.
  case terminal
  /// Several decisions waiting, including plan review and a form.
  case approvals
  /// A 3,000-row transcript.
  case longTranscript
  /// A new session with nothing in it.
  case empty
  /// A failed turn, a connection error and an uncertain send.
  case errors
  /// The layout at iPhone width.
  case compact
  /// Every component on its own page.
  case gallery

  /// The scenario itself.
  public var id: Self { self }

  /// The menu title.
  public var title: String {
    switch self {
    case .streaming: "Streaming Turn"
    case .terminal: "Terminal Mode"
    case .approvals: "Pending Approvals"
    case .longTranscript: "Long Transcript"
    case .empty: "Empty Session"
    case .errors: "Errors"
    case .compact: "Compact Width"
    case .gallery: "Component Gallery"
    }
  }

  /// An SF Symbol.
  public var systemImage: String {
    switch self {
    case .streaming: "ellipsis.bubble"
    case .terminal: "apple.terminal"
    case .approvals: "hand.raised"
    case .longTranscript: "text.line.first.and.arrowtriangle.forward"
    case .empty: "bubble.left"
    case .errors: "exclamationmark.triangle"
    case .compact: "iphone"
    case .gallery: "square.grid.2x2"
    }
  }
}

/// The playground's state: sessions, the selected conversation and drafts, all sample data.
/// Actions mutate it like a store would, so the layout can be exercised by hand.
@Observable
public final class PlaygroundModel {
  /// The active scenario.
  public var scenario: PlaygroundScenario {
    didSet { load(scenario) }
  }

  var list = PreviewData.sessionList
  var selection: String? = PreviewData.sessionID
  var search = ""
  var conversation = PreviewData.conversation
  var composer = PreviewData.composerRunning
  var draft = ""
  var showsInspector = true
  var mode: SessionViewMode = .chat
  /// The selected theme id.
  public var themeID = OmnigentTheme.standard.id
  /// Light, dark or system.
  public var appearance: AppearancePreference = .system

  /// Themes the playground offers: the built-in ones plus a sample.
  public static var themes: [OmnigentTheme] { PreviewData.themes }

  var theme: OmnigentTheme {
    Self.themes.first { $0.id == themeID } ?? .standard
  }
  var showsNewSession = false
  var sidebarItem: PlaygroundSidebarItem? = .filter(.all)

  /// Creates the model.
  /// - Parameter scenario: The first scenario.
  public init(scenario: PlaygroundScenario = .streaming) {
    self.scenario = scenario
    load(scenario)
  }

  private func load(_ scenario: PlaygroundScenario) {
    list = PreviewData.sessionList
    draft = ""
    composer = PreviewData.composerRunning
    mode = .chat
    switch scenario {
    case .streaming, .compact, .gallery:
      conversation = PreviewData.conversation
      conversation.decisions = []
      conversation.terminalAvailable = true
      selection = PreviewData.sessionID
    case .terminal:
      conversation = PreviewData.conversation
      conversation.decisions = [PreviewData.codexCommand]
      conversation.terminalAvailable = true
      mode = .terminal
      selection = PreviewData.sessionID
    case .approvals:
      conversation = PreviewData.conversation
      conversation.header.status = .needsResponse
      conversation.decisions = PreviewData.decisions.filter { !$0.answered }
      composer = PreviewData.composerIdle
      selection = "sess_a2"
    case .longTranscript:
      conversation = PreviewData.largeConversation(count: 3_000)
      composer = PreviewData.composerIdle
      selection = PreviewData.sessionID
    case .empty:
      conversation = PreviewData.emptyConversation
      composer = PreviewData.composerIdle
      list.sessions = []
      list.filterCounts = [:]
      selection = nil
    case .errors:
      conversation = PreviewData.failedConversation
      composer = PreviewData.composerUncertain
      draft = "Retry the dependency bump"
      list.phase = .failed(message: "Could not refresh sessions: the server returned 503.")
      selection = "sess_a3"
    }
  }

  var conversationActions: ConversationActions {
    ConversationActions(
      loadOlder: { [weak self] in self?.conversation.hasMoreHistory = false },
      openSession: { [weak self] id in self?.selection = id },
      openAttachment: { _ in }, openURL: { url in Self.open(url) },
      respond: { [weak self] card, response in self?.respond(card, response) },
      validateForm: PreviewData.validate,
      dismissError: { [weak self] in self?.conversation.errorMessage = nil },
      retry: { [weak self] in self?.conversation.errorMessage = nil })
  }

  var composerActions: ComposerActions {
    ComposerActions(
      send: { [weak self] in self?.send() },
      interrupt: { [weak self] in self?.interrupt() },
      addAttachments: { [weak self] inputs in self?.add(inputs) },
      removeAttachment: { [weak self] attachment in
        self?.composer.attachments.removeAll { $0.id == attachment.id }
      },
      selectModel: { [weak self] id in self?.composer.configuration?.selectedModelId = id },
      selectEffort: { [weak self] effort in self?.composer.configuration?.selectedEffort = effort },
      selectAgent: { [weak self] id in self?.composer.configuration?.selectedAgentId = id },
      acknowledgeUncertainDelivery: { [weak self] in self?.composer.delivery = .idle },
      dismissDeliveryError: { [weak self] in self?.composer.delivery = .idle })
  }

  var listActions: SessionListActions {
    SessionListActions(
      setPinned: { [weak self] session, pinned in
        self?.updateSession(session.id) { $0.isPinned = pinned }
      },
      setArchived: { [weak self] session, archived in
        self?.updateSession(session.id) { $0.isArchived = archived }
      },
      rename: { [weak self] session, title in self?.updateSession(session.id) { $0.title = title }
      },
      setUnread: { [weak self] session, unread in
        if unread {
          self?.list.unreadIds.insert(session.id)
        } else {
          self?.list.unreadIds.remove(session.id)
        }
      },
      webURL: { URL(string: "https://omnigent.example.com/c/\($0.id)") },
      newSession: { [weak self] in self?.showsNewSession = true },
      retry: { [weak self] in self?.list.phase = .loaded })
  }

  private static func open(_ url: URL) {
    #if os(macOS)
      NSWorkspace.shared.open(url)
    #endif
  }

  private func updateSession(_ id: String, _ change: (inout SessionSummary) -> Void) {
    guard let index = list.sessions.firstIndex(where: { $0.id == id }) else { return }
    change(&list.sessions[index])
  }

  private func respond(_ card: DecisionCard, _ response: DecisionResponse) {
    conversation.decisionPhases[card.id] = .answered(summary: response.summary)
    conversation.revision += 1
  }

  private func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !composer.attachments.isEmpty else { return }
    conversation.rows.append(Row(id: "local-\(UUID().uuidString)", role: .user, text: text))
    conversation.rows.append(
      Row(
        id: "live:\(UUID().uuidString)", role: .assistant, text: "", isStreaming: true,
        agent: "Codex", isEphemeral: true))
    conversation.header.status = .running
    conversation.revision += 1
    composer.isRunning = true
    composer.attachments = []
    draft = ""
  }

  private func interrupt() {
    if let index = conversation.rows.lastIndex(where: \.isStreaming) {
      conversation.rows[index].isStreaming = false
      conversation.rows[index].interrupted = true
      if conversation.rows[index].text.isEmpty { conversation.rows[index].text = "Stopped." }
    }
    conversation.header.status = .idle
    conversation.revision += 1
    composer.isRunning = false
  }

  private func add(_ inputs: [ComposerAttachmentInput]) {
    for input in inputs {
      switch input {
      case .file(let url):
        composer.attachments.append(
          DraftAttachment(id: UUID().uuidString, title: url.lastPathComponent, kind: .file))
      case .data(let data, let name, let type):
        composer.attachments.append(
          DraftAttachment(
            id: UUID().uuidString, title: name, kind: type.conforms(to: .image) ? .image : .file,
            byteCount: Int64(data.count)))
      }
    }
  }
}

/// What the playground's sidebar selects.
enum PlaygroundSidebarItem: Hashable {
  case filter(SessionFilter)
  case server(String)
}

/// The full app layout with sample data: a sidebar of servers and filters, the session list,
/// the conversation and the inspector. Used by the playground app and the previews.
public struct PlaygroundView: View {
  @Bindable private var model: PlaygroundModel

  /// Creates the view.
  /// - Parameter model: The playground state.
  public init(model: PlaygroundModel) {
    self.model = model
  }

  /// The layout for the model's scenario.
  public var body: some View {
    Group {
      switch model.scenario {
      case .gallery:
        UIGalleryView()
      case .compact:
        compactLayout
      case .streaming, .terminal, .approvals, .longTranscript, .empty, .errors:
        splitLayout
      }
    }
    .omnigentTheme(model.theme, appearance: model.appearance)
    .sheet(isPresented: $model.showsNewSession) {
      NewSessionView(
        state: PreviewData.newSession,
        actions: NewSessionActions(
          unavailableReason: PreviewData.unavailableReason,
          create: { [model] _, _, _ in model.showsNewSession = false },
          cancel: { [model] in model.showsNewSession = false }),
        initialSelection: CreationSelection(hostId: "host_mbp", agentId: "agent_codex"))
    }
  }

  private var splitLayout: some View {
    NavigationSplitView {
      PlaygroundSidebar(model: model)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
    } content: {
      SessionListView(
        state: model.list, selection: $model.selection, searchText: $model.search,
        actions: model.listActions
      )
      .navigationTitle(model.list.filter.title)
      .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
      .toolbar {
        ToolbarItem {
          Button("New Session", systemImage: "square.and.pencil") { model.showsNewSession = true }
            .help("New session (Command-N)")
        }
      }
    } detail: {
      detail
    }
    .adaptiveLayoutWidth()
  }

  @ViewBuilder private var detail: some View {
    if model.selection == nil, model.scenario == .empty {
      ContentUnavailableView {
        Label("No Session Selected", systemImage: "bubble.left.and.text.bubble.right")
      } description: {
        Text("Start a session to work with an agent.")
      } actions: {
        Button("New Session") { model.showsNewSession = true }
          .buttonStyle(.borderedProminent)
      }
    } else {
      ConversationScreen(
        state: model.conversation, composer: model.composer, draft: $model.draft,
        showsInspector: $model.showsInspector, mode: $model.mode,
        actions: model.conversationActions, composerActions: model.composerActions
      ) {
        TerminalPlaceholderView(harness: model.conversation.header.settings?.harness)
      }
    }
  }

  private var compactLayout: some View {
    HStack {
      Spacer(minLength: 0)
      NavigationStack {
        ConversationScreen(
          state: model.conversation, composer: model.composer, draft: $model.draft,
          showsInspector: $model.showsInspector, mode: $model.mode,
          actions: model.conversationActions, composerActions: model.composerActions
        ) {
          TerminalPlaceholderView(harness: model.conversation.header.settings?.harness)
        }
      }
      .layoutWidth(.compact)
      .environment(\.horizontalSizeClass, .compact)
      .frame(width: 390)
      .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 36, style: .continuous).strokeBorder(
          .separator, lineWidth: 2)
      }
      .padding(24)
      Spacer(minLength: 0)
    }
    .background(.background.secondary)
  }
}

private struct PlaygroundSidebar: View {
  @Bindable var model: PlaygroundModel

  var body: some View {
    List(selection: $model.sidebarItem) {
      Section("Servers") {
        Label("Local Server", systemImage: "server.rack")
          .tag(PlaygroundSidebarItem.server("local"))
        Label("Databricks Dev", systemImage: "cloud")
          .tag(PlaygroundSidebarItem.server("dbx"))
      }
      Section("Sessions") {
        ForEach(SessionFilter.allCases) { filter in
          Label(filter.title, systemImage: filter.systemImage)
            .badge(model.list.filterCounts[filter] ?? 0)
            .tag(PlaygroundSidebarItem.filter(filter))
        }
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("Omnigent")
    .onChange(of: model.sidebarItem) { _, item in
      if case .filter(let filter)? = item { model.list.filter = filter }
    }
  }
}
