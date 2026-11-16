import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI

/// How the window builds a session's chat, for its session chrome to read what the chat's
/// toolbar and right panel are made from. A reference the window refreshes as it renders, so
/// the chrome compares equal across the window's renders: a tab switch does not render it.
@MainActor
final class SessionChromeWiring {
  /// A session's chat as the window builds it; `nil` while the session is not open.
  var chat: @MainActor (String) -> ConversationContainer? = { _ in nil }
}

/// The shown session's toolbar controls and right panel, around the window's tabs
/// (``SessionChrome``): they show whichever tab or pane has the focus, the panel at the
/// window's trailing edge, and act on the session whose tabs the window shows.
struct SessionChromeContainer: ViewModifier {
  let session: ServerSession
  let wiring: SessionChromeWiring

  /// A page without a session follows no file changes.
  private static let noChanges: @MainActor () -> Int = { 0 }

  /// What a page without a session binds (`.constant` counts as changed on every update).
  @State private var noChoice: WorkspacePanelDefault?
  @State private var noExport: TranscriptExport?

  func body(content: Content) -> some View {
    let surface = surface
    let kept = surface?.kept
    let chat = surface?.chat
    let export = kept.map { Bindable($0).export } ?? $noExport
    return
      content
      .sessionChrome(surface?.chrome, panelShown: session.tabs.shownPanel)
      .modifier(SessionChromeCommands(tabs: session.tabs, commands: surface?.commands))
      .fileExporter(
        isPresented: Binding(
          get: { export.wrappedValue != nil }, set: { if !$0 { export.wrappedValue = nil } }),
        document: export.wrappedValue, contentType: TranscriptExport.contentType,
        defaultFilename: "\(chat?.conversation.sessionID ?? "").jsonl",
        onCompletion: { surface?.exportFinished($0) }
      )
      .alert(
        "Something Went Wrong", isPresented: .constant(kept?.failures.messages.isEmpty == false),
        actions: { Button("OK") { kept?.failures.messages = [] } },
        message: { Text(kept?.failures.messages.joined(separator: "\n") ?? "") }
      )
      .task(id: chat?.conversation.sessionID) { await surface?.load() }
      .modifier(PanelRefreshWhenSettled(conversation: chat?.conversation, panel: chat?.panel))
      .modifier(
        WorkspacePanelDefaults(
          workspace: chat?.workspace, choice: kept.map { Bindable($0.panel).choice } ?? $noChoice)
      )
      .modifier(
        ChangedFilesFollower(
          revision: chat?.changedFilesRevision ?? Self.noChanges, workspace: chat?.workspace)
      )
      .countsRenders("chrome")
  }

  /// The shown session's chrome, once its conversation is open.
  private var surface: SessionSurface? {
    guard let sessionID = session.tabs.currentSessionID, let chat = wiring.chat(sessionID)
    else { return nil }
    return SessionSurface(chat: chat, kept: session.tabs.chrome(sessionID))
  }
}

/// One session's chrome: its chat as the window builds it, read for what the toolbar and the
/// right panel show, over the state the window keeps for the session.
@MainActor
struct SessionSurface {
  /// The session's chat, for its inputs only: it is not the view on screen.
  let chat: ConversationContainer
  let kept: SessionChromeState
  /// The session without its transcript: what the toolbar and the right panel read.
  let state: ConversationViewState

  init(chat: ConversationContainer, kept: SessionChromeState) {
    self.chat = chat
    self.kept = kept
    state = chat.adorned(ConversationAdapter.chromeState(chat.conversation, summary: chat.summary))
  }

  var chrome: SessionChrome {
    SessionChrome(
      state: state, extras: extras, actions: actions, mode: Bindable(kept).mode,
      showsInspector: Bindable(kept.panel).isShown, inspectorTab: Bindable(kept).inspectorTab,
      fork: Bindable(kept.forkFlow).sheet)
  }

  private var report: @MainActor (String) -> Void {
    { [failures = kept.failures] in failures.messages.append($0) }
  }

  private var open: @MainActor (String) -> Void { chat.tabRoutes?.openSession ?? chat.openSession }

  private var extras: ConversationExtras {
    let (kept, conversation, report) = (kept, chat.conversation, report)
    var sessionActions = chat.sessionActions
    if let fork = forkSession { sessionActions.fork = { _ in fork() } }
    return ConversationExtras(
      sessionActions: sessionActions, slots: chat.workspaceSlots(routes: toolRoutes),
      sandbox: chat.sandboxActions,
      share: chat.share(over: kept.shareStore),
      forkActions: kept.forkFlow.actions(open: open, report: report),
      menuContext: chat.menuContext,
      exportTranscript: {
        TranscriptExport.read(conversation, into: { kept.export = $0 }, report: report)
      },
      shareOpened: { Task { await kept.shareStore?.load() } })
  }

  /// The session menu's Fork copies the whole session; `nil` when this app cannot fork it.
  private var forkSession: (@MainActor () -> Void)? {
    guard let source = chat.forkSource, let makeStore = chat.makeForkStore else { return nil }
    let context = ForkContext(source: source, upToResponseID: nil, kind: .session)
    return { [flow = kept.forkFlow] in Task { await flow.begin(context, makeStore: makeStore) } }
  }

  /// What the right panel's "Open new" starts and where it reports.
  private var toolRoutes: SessionToolsAdapter.Routes {
    SessionToolsAdapter.Routes(
      openSession: open, openNewSideChat: chat.tabRoutes?.openNewSideChat,
      awaitForkedSideChat: chat.tabRoutes?.awaitForkedSideChat,
      showPullRequests: { [kept] in kept.show(.pullRequests) }, showGoal: {}, report: report)
  }

  /// What the right panel opens.
  private var actions: ConversationActions {
    let (conversation, opener, report) = (chat.conversation, chat.opener, report)
    return ConversationActions(
      openSession: open,
      openURL: { url in
        Task { if !(await opener.open(url)) { report("Could not open \(url.absoluteString).") } }
      },
      dismissError: { conversation.dismissErrors() })
  }

  /// The menu commands the session answers while the focused tab is not a conversation, which
  /// publishes its own: the right panel, Chat or Terminal, and the sessions beside this one.
  var commands: SessionCommandActions {
    let kept = kept
    var toggleMode: (@MainActor () -> Void)?
    if state.terminalAvailable {
      toggleMode = { kept.mode = kept.mode == .chat ? .terminal : .chat }
    }
    var openChanges: (@MainActor () -> Void)?
    if let panel = chat.tabRoutes?.windowPanel { openChanges = { panel.show(.changes) } }
    var commands = SessionCommandActions(
      toggleInspector: { kept.panel.isShown.toggle() },
      previousSession: chat.navigation.previousSession, nextSession: chat.navigation.nextSession,
      toggleViewMode: toggleMode, openChanges: openChanges)
    commands.addNestedAgent = chrome.addNestedAgentCommand
    return commands
  }

  /// The save panel closed: a file that couldn't be written goes in the session's alert.
  func exportFinished(_ result: Result<URL, any Error>) {
    TranscriptExport.finished(result, report: report)
  }

  /// Reads what the chrome shows that the chat's own view read for itself: who the session is
  /// shared with, and the right panel's features and pull requests.
  func load() async {
    if kept.shareStore == nil { kept.shareStore = chat.makeShareStore?() }
    // Once per session for the window, as a kept chat read them: not again on each return.
    guard !kept.hasReadPullRequests else { return }
    kept.hasReadPullRequests = true
    await chat.panel?.reloadPullRequests()
  }
}

/// Publishes the session's menu commands while the focused tab is not a conversation: the
/// focused pane's conversation publishes its own. The focused tab is read here, so a tab
/// switch runs this body and not the chrome's.
private struct SessionChromeCommands: ViewModifier {
  let tabs: SessionTabGroups
  let commands: SessionCommandActions?
  @State private var relay = FocusedActionsRelay<SessionCommandActions>()

  func body(content: Content) -> some View {
    let showsConversation = tabs.selected?.content.showsConversation ?? true
    return content.focusedSceneValue(
      \.sessionCommands, relay.publish(showsConversation ? nil : commands))
  }
}

/// Re-reads the session's pull requests after a turn that may have opened or pushed to one.
/// The turn is read here, so it renders nothing of the chrome.
private struct PanelRefreshWhenSettled: ViewModifier {
  let conversation: ConversationStore?
  let panel: SessionPanelStore?

  func body(content: Content) -> some View {
    // Only a turn that ran: a chat that only now opens is not a turn that ended.
    content.onChange(of: conversation?.isRunning) { wasRunning, running in
      if wasRunning == true, running == false {
        Task { await panel?.refreshPullRequestsIfShown() }
      }
    }
  }
}

extension AppTabContent {
  /// Whether the tab shows a conversation, which answers the Conversation menu itself.
  var showsConversation: Bool {
    switch self {
    case .chat, .harness, .subagent: true
    case .sideChatSession(_, let childID): childID != nil
    case .newTab, .newSession, .nestedSession, .inbox, .canvas, .automations, .usage, .terminal,
      .sideChat, .browser, .agentBrowser, .remoteBrowser:
      false
    }
  }
}
