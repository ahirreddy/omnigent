import Foundation
import Observation
import OmnigentStores
import OmnigentUIComponents

/// What a window keeps of a session's toolbar controls and right panel: whether the panel shows
/// and on which tab, and the session menu's Fork, Share and Export. Kept for the window's life,
/// so a session that shows again has its panel as it was left.
@Observable
final class SessionChromeState {
  /// Whether a window shows its session's toolbar controls and right panel around its tabs, as
  /// a Mac window does. Elsewhere each conversation shows its own: the panel is a column of the
  /// chat on iPad and a sheet on iPhone.
  static let isWindowHosted: Bool = {
    #if os(macOS)
      return true
    #else
      return false
    #endif
  }()

  /// Whether the right panel shows.
  let panel = ConversationPanelRoute()
  /// The right panel's tab.
  var inspectorTab = DefaultWorkspaceTab.stored().inspectorTab
  /// The session menu's Fork.
  let forkFlow = ForkFlow()
  /// What the session's alert reports.
  let failures = ConversationFailures()
  /// The transcript the save panel is asking where to put.
  var export: TranscriptExport?
  /// The Share sheet's grants, once the session is open.
  var shareStore: ShareStore?
  /// The right panel's pull requests were read once; after that a turn's end reads them.
  @ObservationIgnored var hasReadPullRequests = false
  /// The session chat's Chat or Terminal choice.
  private let viewChoice: SessionViewChoice
  /// Brings the session's chat on screen when no pane shows it.
  private let revealChat: @MainActor () -> Void

  /// Creates the state.
  /// - Parameters:
  ///   - viewChoice: The session chat's Chat or Terminal choice.
  ///   - revealChat: Brings the session's chat on screen when no pane shows it.
  init(viewChoice: SessionViewChoice, revealChat: @escaping @MainActor () -> Void) {
    self.viewChoice = viewChoice
    self.revealChat = revealChat
    panel.startsShown(WorkspacePanelDefault.stored().showsPanel(isSheet: false))
  }

  /// Whether the session's chat shows its transcript or its agent's terminal. Choosing one
  /// from another tab also shows the chat, so the choice is never made out of sight.
  var mode: SessionViewMode {
    get { viewChoice.mode ?? .chat }
    set {
      if viewChoice.mode != newValue { viewChoice.mode = newValue }
      revealChat()
    }
  }

  /// Shows the right panel on `tab`.
  func show(_ tab: InspectorTab) {
    if inspectorTab != tab { inspectorTab = tab }
    panel.isShown = true
  }
}

extension SessionTabGroups {
  /// A session's toolbar and right-panel state in this window, for the window's life.
  /// - Parameter sessionID: The session whose tabs the window shows.
  /// - Returns: The state.
  func chrome(_ sessionID: String) -> SessionChromeState {
    if let chrome = chromes[sessionID] { return chrome }
    let chrome = SessionChromeState(viewChoice: viewChoice(sessionID)) { [weak self] in
      self?.revealChat(sessionID)
    }
    chromes[sessionID] = chrome
    return chrome
  }

  /// Whether the shown session's right panel shows; never on a page without a session. The
  /// window's panel binds here, not to one session's state: SwiftUI's inspector may still write
  /// the binding it had after the session changed, and that must not reach the session left.
  var shownPanelIsShown: Bool {
    get { currentSessionID.map { chrome($0).panel.isShown } ?? false }
    set {
      if let sessionID = currentSessionID { chrome(sessionID).panel.isShown = newValue }
    }
  }

  /// Brings a session's chat on screen unless a pane already shows it.
  /// - Parameter sessionID: The session.
  func revealChat(_ sessionID: String) {
    let chat = AppTabContent.chat(sessionID: sessionID)
    let isShown = groups[sessionID]?.shownTabs.contains { $0.content == chat } ?? false
    if !isShown { showChat(sessionID) }
  }
}
