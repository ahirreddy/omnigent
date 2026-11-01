import Foundation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentStores
public import OmnigentUIComponents
public import SwiftUI

/// The signed-in app for one server: the web's two-column shell (`AppShell`: sidebar and detail,
/// with the session's right panel as the detail's inspector), collapsing to a stack on iPhone.
///
/// Selecting a session opens its conversation, terminals and workspace in the core and closes
/// the previous one; the core is told which session is visible for notifications and the badge.
public struct ConnectedServerView: View {
  private let session: ServerSession
  @Binding private var selection: SidebarDestination?
  private let isWindowFocused: Bool
  private let opener: ExternalURLOpener
  private let openInNewWindow: (@MainActor (String) -> Void)?

  @State private var display = SessionDisplayOptions()
  @State private var undo: SidebarUndo?

  /// Creates the view.
  /// - Parameters:
  ///   - session: The signed-in connection.
  ///   - selection: What the detail shows; the host keeps it so deep links can set it.
  ///   - isWindowFocused: Whether the window is key, for notification suppression.
  ///   - opener: Opens pages in the system browser.
  ///   - openInNewWindow: Opens a session in a new window, where the platform has windows.
  public init(
    session: ServerSession, selection: Binding<SidebarDestination?>,
    isWindowFocused: Bool = true, opener: ExternalURLOpener = .system,
    openInNewWindow: (@MainActor (String) -> Void)? = nil
  ) {
    self.session = session
    _selection = selection
    self.isWindowFocused = isWindowFocused
    self.opener = opener
    self.openInNewWindow = openInNewWindow
  }

  private var connection: ConnectionStore { session.connection }

  public var body: some View {
    AppShell(
      sidebar: sidebarState, selection: $selection, searchText: searchBinding,
      actions: sidebarActions
    ) { destination in
      detail(destination)
        .safeAreaInset(edge: .top, spacing: 0) {
          ConnectionIssuesBanner(connection: connection)
        }
    }
    .toolbar { accountToolbar }
    .onChange(of: selection, initial: true) { previous, current in
      select(from: previous?.sessionID, to: current?.sessionID)
    }
    .onChange(of: isWindowFocused) { report() }
    .alert(
      "Could Not Update the Session", isPresented: editErrorPresented,
      actions: { Button("OK") { connection.sessionList.dismissEditError() } },
      message: { Text(connection.sessionList.editError?.message ?? "") })
  }

  private var sidebarState: SidebarViewState {
    var state = SidebarAdapter.state(
      list: connection.sessionList, notifications: connection.notifications,
      display: display, server: connection.connectedServer)
    state.undo = undo?.banner
    return state
  }

  private var searchBinding: Binding<String> {
    let list = connection.sessionList
    return Binding(get: { list.searchText }, set: { list.searchText = $0 })
  }

  private var editErrorPresented: Binding<Bool> {
    let list = connection.sessionList
    return Binding(
      get: { list.editError != nil }, set: { if !$0 { list.dismissEditError() } })
  }

  @ToolbarContentBuilder private var accountToolbar: some ToolbarContent {
    if case .connected(let account) = session.signIn.state.phase, account.canSignOut {
      ToolbarItem(placement: .automatic) {
        AccountChip(account: account, actions: session.signIn.actions)
      }
    }
  }

  @ViewBuilder private func detail(_ destination: SidebarDestination?) -> some View {
    switch destination {
    case .session(let id):
      if let conversation = connection.conversations[id] {
        ConversationContainer(
          conversation: conversation, summary: connection.sessionList.session(id),
          terminals: session.terminalStores[id], workspace: session.workspaces[id],
          changedFilesRevision: connection.changedFilesRevision,
          navigation: navigation(from: id), opener: opener,
          openSession: { selection = .session($0) },
          retry: { connection.foreground() }
        )
        .id(id)
      } else {
        ProgressView("Opening the session\u{2026}")
      }
    case .newSession:
      NewSessionContainer(connection: connection) { selection = .session($0) }
    case .inbox:
      InboxView(
        state: InboxAdapter.state(
          list: connection.sessionList, notifications: connection.notifications),
        actions: InboxActions(open: { selection = .session($0.sessionId) }))
    case .canvas:
      CanvasView(
        sessions: connection.sessionList.visible.map(OmnigentUIComponents.SessionSummary.init),
        open: { selection = .session($0) })
    case nil:
      ContentUnavailableView {
        Label("No Session Selected", systemImage: "bubble.left.and.text.bubble.right")
      } description: {
        Text("Choose a session in the sidebar, or start a new one.")
      }
    }
  }

  private var sidebarActions: SidebarActions {
    let list = connection.sessionList
    let connection = connection
    let server = connection.connectedServer
    var openInWindow: (@MainActor (OmnigentUIComponents.SessionSummary) -> Void)?
    if let open = openInNewWindow {
      openInWindow = { summary in open(summary.id) }
    }
    return SidebarActions(
      sessions: SessionListActions(
        setFilter: { list.filter = OmnigentCoreFFI.SessionFilter($0) },
        setPinned: { summary, pinned in edit(.pin(summary.id, pinned)) },
        setArchived: { summary, archived in edit(.archive([summary.id], archived)) },
        rename: { summary, title in rename(summary.id, to: title) },
        openInNewWindow: openInWindow,
        webURL: { SidebarAdapter.webURL(server: server, sessionID: $0.id) },
        newSession: { selection = .newSession },
        retry: { connection.refreshSessions() }),
      setDisplay: { display = $0 },
      setQuickFilter: { list.filter = OmnigentCoreFFI.SessionFilter($0 ?? .all) },
      undo: { _ in
        guard let undo else { return }
        self.undo = nil
        edit(undo.inverse, recordUndo: false)
      },
      dismissUndo: { undo = nil },
      viewArchived: { list.filter = .archived })
  }

  /// Renames through the session list, which reports a failure in `editError` (shown above).
  private func rename(_ sessionID: String, to title: String) {
    let list = connection.sessionList
    Task {
      // The Boolean only repeats whether `editError` was set.
      _ = await list.rename(sessionID, to: title)
    }
  }

  /// Pins or archives through the session list (which reports failures in `editError`), and
  /// offers Undo for the change.
  private func edit(_ change: SidebarUndo.Change, recordUndo: Bool = true) {
    let list = connection.sessionList
    Task {
      var succeeded = true
      switch change {
      case .pin(let id, let pinned):
        succeeded = await list.setPinned(id, pinned)
      case .archive(let ids, let archived):
        for id in ids where succeeded {
          succeeded = await list.setArchived(id, archived)
        }
        if archived, let current = selection?.sessionID, ids.contains(current) {
          selection = nil
        }
      }
      if succeeded, recordUndo { undo = SidebarUndo(change: change) }
    }
  }

  /// Previous and next session in the sidebar's order.
  private func navigation(from id: String) -> SessionCommandActions {
    let ids = connection.sessionList.visible.map(\.id)
    guard let index = ids.firstIndex(of: id) else { return SessionCommandActions() }
    let previous = index > ids.startIndex ? ids[index - 1] : nil
    let next = index + 1 < ids.endIndex ? ids[index + 1] : nil
    var actions = SessionCommandActions()
    if let previous {
      actions.previousSession = { selection = .session(previous) }
    }
    if let next {
      actions.nextSession = { selection = .session(next) }
    }
    return actions
  }

  private func select(from previous: String?, to current: String?) {
    if let previous, previous != current { session.close(previous) }
    if let current { session.open(current) }
    report()
  }

  private func report() {
    connection.setView(sessionID: selection?.sessionID, focused: isWindowFocused)
  }
}

/// A sidebar change the user can undo from the undo bar.
struct SidebarUndo: Identifiable {
  enum Change {
    case pin(String, Bool)
    case archive([String], Bool)
  }

  let id = UUID().uuidString
  let change: Change

  var banner: UndoBanner? {
    switch change {
    case .pin(_, let pinned): UndoBanner(id: id, kind: pinned ? .pinned : .unpinned)
    case .archive(let ids, true): UndoBanner(id: id, kind: .archived(count: ids.count))
    case .archive(_, false): nil
    }
  }

  var inverse: Change {
    switch change {
    case .pin(let id, let pinned): .pin(id, !pinned)
    case .archive(let ids, let archived): .archive(ids, !archived)
    }
  }
}
