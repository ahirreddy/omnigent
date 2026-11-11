public import Foundation
import OSLog
import Observation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The servers a window's sidebar switcher offers, and what switching does. The host owns the
/// windows, so it decides how a window moves to another server.
public struct ServerSwitching {
  /// Known servers (default, recent and the organization's), the current one included or not.
  public var servers: [URL]
  /// Moves this window to `url`.
  public var switchTo: @MainActor (URL) -> Void
  /// Connects another server.
  public var addServer: @MainActor () -> Void
  /// Opens server settings.
  public var openSettings: (@MainActor () -> Void)?
  /// The servers among `servers` that the user's organization provides.
  public var organizationServers: [URL]

  /// Creates the switcher.
  /// - Parameters:
  ///   - servers: Known servers.
  ///   - organizationServers: Those the organization provides ("Provided by your organization").
  ///   - switchTo: Moves the window.
  ///   - addServer: Connects another server.
  ///   - openSettings: Opens server settings.
  public init(
    servers: [URL], organizationServers: [URL] = [], switchTo: @escaping @MainActor (URL) -> Void,
    addServer: @escaping @MainActor () -> Void, openSettings: (@MainActor () -> Void)? = nil
  ) {
    self.servers = servers
    self.organizationServers = organizationServers
    self.switchTo = switchTo
    self.addServer = addServer
    self.openSettings = openSettings
  }

  /// The switcher's rows, one per server, ids normalized so the current server matches.
  var choices: [ServerChoice] {
    let organization = Set(organizationServers.map { ServerChoice.normalizedID($0.absoluteString) })
    var seen = Set<String>()
    return servers.compactMap { url in
      let id = ServerChoice.normalizedID(url.absoluteString)
      guard seen.insert(id).inserted else { return nil }
      return ServerChoice(
        id: id,
        name: ExecutionContext.serverDisplayName(name: nil, baseURL: url.absoluteString),
        url: url.absoluteString, isConnected: false, isOrganization: organization.contains(id))
    }
  }
}

extension ServerChoice {
  /// A server's id: its URL, lowercased, without a trailing slash.
  static func normalizedID(_ url: String) -> String {
    var text = url.lowercased()
    while text.hasSuffix("/") { text.removeLast() }
    return text
  }
}

/// The sidebar's display options, kept across launches under the web's key.
enum SidebarDisplayDefaults {
  static let key = "omnigent:sidebar-view"

  /// The saved options, or the defaults.
  static func load(_ defaults: UserDefaults = .standard) -> SessionDisplayOptions {
    guard let data = defaults.data(forKey: key) else { return SessionDisplayOptions() }
    do {
      return try JSONDecoder().decode(SessionDisplayOptions.self, from: data)
    } catch {
      // Options saved by an older build that no longer decode fall back to the defaults.
      defaults.removeObject(forKey: key)
      return SessionDisplayOptions()
    }
  }

  /// Saves `options`.
  static func save(
    _ options: SessionDisplayOptions, _ defaults: UserDefaults = .standard,
    encode: (SessionDisplayOptions) throws -> Data = { try JSONEncoder().encode($0) }
  ) {
    do {
      defaults.set(try encode(options), forKey: key)
    } catch {
      // The last saved options stay; the choice lasts until the window closes.
      Logger(subsystem: "ai.omnigent.app", category: "sidebar").error(
        "Could not encode the sidebar display options: \(String(describing: error), privacy: .public)"
      )
    }
  }
}

extension SessionDisplayOptions {
  /// A copy showing `show`.
  func with(show: SessionShowScope) -> Self {
    var copy = self
    copy.show = show
    return copy
  }
}

/// The sidebar's state that outlives a view update: display options, the undo banner, and the
/// fork, share and archive-worktree dialogs.
@Observable
final class SidebarModel {
  var display = SidebarDisplayDefaults.load()
  var undo: SidebarUndo?
  /// The open Project settings sheet.
  var projectSettings: ProjectSettingsFlow?
  let fork = ForkFlow()
  /// The session a row's Share opened.
  var share: ShareStore?
  /// An archive waiting on whether to delete worktrees.
  var archiveRequest: ArchiveWorktreeRequest?
  /// The session a chat tab's menu is renaming.
  var renamingFromTab: OmnigentUIComponents.SessionSummary?
  var renameText = ""

  /// Asks for a new title for a chat tab's session, as the session menu does.
  func askToRename(tabID: String, tabs: SessionTabGroups, list: SessionListStore) {
    guard let id = tabs.tab(tabID)?.sessionID, let summary = list.session(id) else { return }
    renameText = summary.title
    renamingFromTab = OmnigentUIComponents.SessionSummary(summary)
  }
}

// MARK: Actions

extension ConnectedServerView {
  /// The connected account when it can sign out: the sidebar's footer and Sign Out show only then.
  var signOutAccount: SignedInAccount? {
    guard case .connected(server: let account) = session.signIn.state.phase, account.canSignOut
    else { return nil }
    return account
  }

  var sidebarActions: SidebarActions {
    let model = sidebarModel
    var actions = SidebarActions(
      sessions: sessionListActions,
      setDisplay: { setDisplay($0) },
      setQuickFilter: { setQuickFilter($0) },
      undo: { _ in
        guard let undo = model.undo else { return }
        model.undo = nil
        edit(undo.inverse, recordUndo: false)
        if let warning = undo.lostWorktreeWarning(now: .now) {
          connection.sessionList.reportFailure(.InvalidState(message: warning))
        }
      },
      dismissUndo: { model.undo = nil },
      viewArchived: { setDisplay(model.display.with(show: .archived)) })
    if let serverSwitching {
      actions.switchServer = { choice in
        if let url = URL(string: choice.url) { serverSwitching.switchTo(url) }
      }
      actions.addServer = serverSwitching.addServer
      actions.openServerSettings = serverSwitching.openSettings
    }
    if signOutAccount != nil {
      let signIn = session.signIn.actions
      actions.signOut = { signIn.signOut() }
    }
    actions.setArchivedMany = { sessions, archived in
      requestArchive(sessions.map(\.id), archived: archived)
    }
    actions.dropSession = { session, action in drop(session, action) }
    actions.live = SidebarAdapter.live(connection.sessionList)
    let paging = connection.sessionList.paging
    actions.loadMoreSessions = { paging.loadMore() }
    actions.loadProjectPage = { project in
      Task { await paging.loadProject(ProjectSummary(project), id: project.id) }
    }
    return withProjectActions(actions)
  }

  var sessionListActions: SessionListActions {
    let list = connection.sessionList
    let connection = connection
    let server = connection.connectedServer
    let selection = selectionBinding
    var openInWindow: (@MainActor (OmnigentUIComponents.SessionSummary) -> Void)?
    if let open = openInNewWindow {
      openInWindow = { summary in open(summary.id) }
    }
    var actions = SessionListActions(
      setFilter: { list.filter = OmnigentCoreFFI.SessionFilter($0) },
      setPinned: { summary, pinned in edit(.pin(summary.id, pinned)) },
      setArchived: { summary, archived in requestArchive([summary.id], archived: archived) },
      rename: { summary, title in rename(summary.id, to: title) },
      setUnread: { summary, unread in Task { await list.setUnread(summary.id, unread) } },
      share: shareAction,
      fork: { summary in beginSidebarFork(summary.id) },
      moveToProject: { summary, project in
        move(summary.id, to: project.map(ProjectSummary.init))
      },
      stop: { summary in Task { await list.stop(summary.id) } },
      delete: { summary in removeSession(summary.id) { await list.delete($0) } },
      leave: { summary in removeSession(summary.id) { await list.leave($0) } },
      openInNewWindow: openInWindow,
      webURL: { SidebarAdapter.webURL(server: server, sessionID: $0.id) },
      newSession: { selection.wrappedValue = .newSession },
      retry: { connection.refreshSessions() })
    actions.deleteWithBranch = { summary, deleteBranch in
      removeSession(summary.id) { await list.delete($0, deleteBranch: deleteBranch) }
    }
    // Split view holds two tabs of one session; another session goes beside it in a window
    // (Open in New Window), so the rows offer no Open in Split View.
    actions.shareUnavailableReason = shareUnavailableReason
    actions.forkUnavailableReason = { summary in
      list.sessionWithoutActivity(summary.id).flatMap { forkUnavailableReason(source: $0) }
    }
    return actions
  }

  /// Saves the display options; Show > Archived is the archived list.
  func setDisplay(_ options: SessionDisplayOptions) {
    let list = connection.sessionList
    if options.show == .archived {
      list.filter = .archived
    } else if sidebarModel.display.show == .archived {
      list.filter = .all
    }
    sidebarModel.display = options
    SidebarDisplayDefaults.save(options)
  }

  /// A quick filter leaves the archived list.
  func setQuickFilter(_ filter: OmnigentUIComponents.SessionFilter?) {
    let model = sidebarModel
    if model.display.show == .archived { setDisplay(model.display.with(show: .all)) }
    connection.sessionList.filter = OmnigentCoreFFI.SessionFilter(filter ?? .all)
  }

  /// Previous and Next Session, and the pinned-session shortcuts, show the session's tabs.
  func showInPlace(_ sessionID: String) {
    selectionBinding.wrappedValue = .session(sessionID)
  }

  /// Previous and next session in the sidebar's order, wrapping at the ends as on the web. The
  /// order is read when the key is pressed, so a list update doesn't republish the menus.
  func navigation(from id: String) -> SessionCommandActions {
    guard connection.sessionList.hasSeveralVisible else { return SessionCommandActions() }
    var actions = SessionCommandActions()
    actions.previousSession = { stepSession(from: id, by: -1) }
    actions.nextSession = { stepSession(from: id, by: 1) }
    return actions
  }

  private func stepSession(from id: String, by offset: Int) {
    let order = SidebarNavigationOrder.sessionIDs(sidebarState)
    if let target = SidebarNavigationOrder.step(from: id, by: offset, in: order) {
      showInPlace(target)
    }
  }

  /// Control-Command-digit: the pinned session at `index`, in the Pinned section's order.
  func openPinnedSession(_ index: Int) {
    let pinned = SidebarNavigationOrder.pinnedIDs(sidebarState)
    guard pinned.indices.contains(index) else { return }
    showInPlace(pinned[index])
  }

  func report() {
    connection.setView(sessionID: session.tabs.viewedSessionID, focused: isWindowFocused)
  }
}

// MARK: Fork from the sidebar

extension ConnectedServerView {
  var sidebarForkPresented: Binding<Bool> {
    let flow = sidebarModel.fork
    return Binding(get: { flow.viewState != nil }, set: { if !$0 { flow.cancel() } })
  }

  /// The fork shows in the window, with its chat.
  var sidebarForkActions: ForkActions {
    let flow = sidebarModel.fork
    let tabs = session.tabs
    let list = connection.sessionList
    return flow.withSandboxActions(
      ForkActions(
        forkWith: { choices in
          Task {
            await flow.fork(
              choices, open: { tabs.showChat($0) },
              report: { message in
                list.reportFailure(.InvalidState(message: message))
              })
          }
        },
        selectionChanged: { agentID, hostID in
          Task { await flow.selectionChanged(agentID: agentID, hostID: hostID) }
        },
        cancel: { flow.cancel() }))
  }

  /// Opens the fork sheet for a whole session, when this app can fork it.
  func beginSidebarFork(_ sessionID: String) {
    let connection = connection
    guard let source = connection.sessionList.session(sessionID) else { return }
    if let reason = forkUnavailableReason(source: source) {
      connection.sessionList.reportFailure(.InvalidState(message: reason))
      return
    }
    let flow = sidebarModel.fork
    Task {
      await flow.begin(
        ForkContext(source: source, upToResponseID: nil, kind: .session),
        makeStore: { connection.makeForkStore() })
    }
  }
}
