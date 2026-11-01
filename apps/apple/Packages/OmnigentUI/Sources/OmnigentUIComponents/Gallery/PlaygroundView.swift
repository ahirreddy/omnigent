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
  /// A native-harness session in Terminal mode.
  case terminal
  /// Several decisions waiting, inline and docked.
  case approvals
  /// A 3,000-row transcript.
  case longTranscript
  /// The new-session page ("What should we build?").
  case newSession
  /// The Inbox.
  case inbox
  /// No sessions yet.
  case empty
  /// A failed turn, a connection error, an offline sandbox and an uncertain send.
  case errors
  /// The layout at iPhone width.
  case compact
  /// Server settings panes.
  case serverSettings
  /// Every theme side by side.
  case themes
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
    case .newSession: "New Session"
    case .inbox: "Inbox"
    case .empty: "Empty"
    case .errors: "Errors"
    case .compact: "Compact Width"
    case .serverSettings: "Server Settings"
    case .themes: "Theme Gallery"
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
    case .newSession: "plus.bubble"
    case .inbox: "tray"
    case .empty: "bubble.left"
    case .errors: "exclamationmark.triangle"
    case .compact: "iphone"
    case .serverSettings: "server.rack"
    case .themes: "paintpalette"
    case .gallery: "square.grid.2x2"
    }
  }
}

/// The playground's state: sample data mutated like a store would, so the layout can be
/// exercised by hand.
@Observable
public final class PlaygroundModel {
  /// The active scenario.
  public var scenario: PlaygroundScenario {
    didSet { load(scenario) }
  }
  /// Appearance preferences (stored in a private defaults suite, not the app's).
  public let preferences: ThemePreferences

  var sidebar = PreviewData.sidebar
  var selection: SidebarDestination? = .session(PreviewData.sessionID)
  var search = ""
  var conversation = PreviewData.shellConversation
  var composer = PreviewData.sessionComposer
  var startComposer = PreviewData.startComposer
  var draft = ""
  var startDraft = ""
  var showsInspector = false
  var mode: SessionViewMode = .chat
  var fork: ForkViewState?
  var share = PreviewData.share
  var inbox = PreviewData.inbox

  /// Creates the model.
  /// - Parameters:
  ///   - scenario: The first scenario.
  ///   - preferences: Appearance preferences; a scratch suite by default.
  public init(
    scenario: PlaygroundScenario = .streaming,
    preferences: ThemePreferences = ThemePreferences(
      defaults: UserDefaults(suiteName: "ai.omnigent.playground") ?? .standard)
  ) {
    self.scenario = scenario
    self.preferences = preferences
    load(scenario)
  }

  private func load(_ scenario: PlaygroundScenario) {
    sidebar = PreviewData.sidebar
    conversation = PreviewData.shellConversation
    composer = PreviewData.sessionComposer
    draft = ""
    mode = .chat
    selection = .session(PreviewData.sessionID)
    showsInspector = false
    switch scenario {
    case .streaming, .compact, .gallery, .themes, .serverSettings:
      conversation.decisions = []
    case .terminal:
      conversation.decisions = [PreviewData.codexCommand]
      mode = .terminal
      showsInspector = true
    case .approvals:
      conversation.header.status = .needsResponse
      conversation.decisions = PreviewData.decisions.filter { !$0.answered }
      composer = PreviewData.idleSessionComposer
      composer.placeholder = "Respond to the pending request above to continue"
    case .longTranscript:
      conversation = PreviewData.largeConversation(count: 3_000)
      composer = PreviewData.idleSessionComposer
    case .newSession:
      selection = .newSession
    case .inbox:
      selection = .inbox
    case .empty:
      sidebar.list.sessions = []
      sidebar.projects = []
      sidebar.list.filterCounts = [:]
      sidebar.inboxCount = 0
      selection = .newSession
    case .errors:
      conversation = PreviewData.failedConversation
      conversation.summary = PreviewData.sessions.first { $0.id == "sess_a3" }
      conversation.terminal = .sandboxOffline
      composer = PreviewData.idleSessionComposer
      composer.delivery = PreviewData.composerUncertain.delivery
      draft = "Retry the dependency bump"
      sidebar.list.phase = .failed(message: "Could not refresh sessions: the server returned 503.")
      sidebar.undo = UndoBanner(id: "undo1", kind: .archived(count: 1))
      selection = .session("sess_a3")
    }
  }

  static func open(_ url: URL) {
    #if os(macOS)
      NSWorkspace.shared.open(url)
    #endif
  }

  func updateSession(_ id: String, _ change: (inout SessionSummary) -> Void) {
    guard let index = sidebar.list.sessions.firstIndex(where: { $0.id == id }) else { return }
    change(&sidebar.list.sessions[index])
  }

  func respond(_ card: DecisionCard, _ response: DecisionResponse) {
    conversation.decisionPhases[card.id] = .answered(summary: response.summary)
    conversation.revision += 1
  }

  func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !composer.attachments.isEmpty else { return }
    if composer.isRunning {
      composer.queue.append(QueuedMessage(id: UUID().uuidString, text: text))
      draft = ""
      return
    }
    conversation.rows.append(Row(id: "local-\(UUID().uuidString)", role: .user, text: text))
    conversation.rows.append(
      Row(
        id: "live:\(UUID().uuidString)", role: .assistant, text: "", isStreaming: true,
        responseId: "resp_live", isEphemeral: true))
    conversation.header.status = .running
    conversation.revision += 1
    composer.isRunning = true
    composer.attachments = []
    draft = ""
  }

  func start() {
    let text = startDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let id = "sess_new_\(sidebar.list.sessions.count)"
    sidebar.list.sessions.insert(
      SessionSummary(
        id: id, title: String(text.prefix(48)), preview: text, status: .running,
        updatedAt: Int64(Date().timeIntervalSince1970), agentName: "Claude Code"), at: 0)
    var state = PreviewData.emptyConversation
    state.header = SessionHeader(id: id, title: String(text.prefix(48)), status: .running)
    state.rows = [
      Row(id: "u-\(id)", role: .user, text: text),
      Row(id: "live:\(id)", role: .assistant, text: "", isStreaming: true, isEphemeral: true),
    ]
    conversation = state
    composer = PreviewData.sessionComposer
    composer.queue = []
    startDraft = ""
    selection = .session(id)
  }

  func interrupt() {
    if let index = conversation.rows.lastIndex(where: \.isStreaming) {
      conversation.rows[index].isStreaming = false
      conversation.rows[index].interrupted = true
      if conversation.rows[index].text.isEmpty { conversation.rows[index].text = "Stopped." }
    }
    conversation.header.status = .idle
    conversation.revision += 1
    composer.isRunning = false
  }

  func add(_ inputs: [ComposerAttachmentInput]) {
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
