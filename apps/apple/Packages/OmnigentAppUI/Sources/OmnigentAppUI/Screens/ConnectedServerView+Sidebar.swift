public import Foundation
import Observation
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

  /// Creates the switcher.
  /// - Parameters:
  ///   - servers: Known servers.
  ///   - switchTo: Moves the window.
  ///   - addServer: Connects another server.
  ///   - openSettings: Opens server settings.
  public init(
    servers: [URL], switchTo: @escaping @MainActor (URL) -> Void,
    addServer: @escaping @MainActor () -> Void, openSettings: (@MainActor () -> Void)? = nil
  ) {
    self.servers = servers
    self.switchTo = switchTo
    self.addServer = addServer
    self.openSettings = openSettings
  }

  /// The switcher's rows, one per server, ids normalized so the current server matches.
  var choices: [ServerChoice] {
    var seen = Set<String>()
    return servers.compactMap { url in
      let id = ServerChoice.normalizedID(url.absoluteString)
      guard seen.insert(id).inserted else { return nil }
      return ServerChoice(
        id: id,
        name: ExecutionContext.serverDisplayName(name: nil, baseURL: url.absoluteString),
        url: url.absoluteString, isConnected: false)
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
  static func save(_ options: SessionDisplayOptions, _ defaults: UserDefaults = .standard) {
    do {
      defaults.set(try JSONEncoder().encode(options), forKey: key)
    } catch {
      // Every field is a plain enum or set of them, so encoding cannot fail.
      assertionFailure("Could not encode the sidebar display options: \(error)")
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

/// The sidebar's state that outlives a view update: display options, the undo banner and the
/// fork sheet.
@Observable
final class SidebarModel {
  var display = SidebarDisplayDefaults.load()
  var undo: SidebarUndo?
  let fork = ForkFlow()
}

// MARK: Actions

extension ConnectedServerView {
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
    let list = connection.sessionList
    actions.createProject = { name, moving in
      Task {
        guard let project = await list.createProject(named: name), let moving else { return }
        await list.move(moving.id, to: project)
      }
    }
    actions.renameProject = { project, name in
      Task { await list.renameProject(ProjectSummary(project), to: name) }
    }
    actions.deleteProject = { project in
      Task { await list.deleteProject(ProjectSummary(project)) }
    }
    return actions
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
    return SessionListActions(
      setFilter: { list.filter = OmnigentCoreFFI.SessionFilter($0) },
      setPinned: { summary, pinned in edit(.pin(summary.id, pinned)) },
      setArchived: { summary, archived in edit(.archive([summary.id], archived)) },
      rename: { summary, title in rename(summary.id, to: title) },
      setUnread: { summary, unread in Task { await list.setUnread(summary.id, unread) } },
      fork: { summary in beginSidebarFork(summary.id) },
      moveToProject: { summary, project in
        Task { await list.move(summary.id, to: project.map(ProjectSummary.init)) }
      },
      stop: { summary in Task { await list.stop(summary.id) } },
      delete: { summary in removeSession(summary.id) { await list.delete($0) } },
      leave: { summary in removeSession(summary.id) { await list.leave($0) } },
      openInNewWindow: openInWindow,
      webURL: { SidebarAdapter.webURL(server: server, sessionID: $0.id) },
      newSession: { selection.wrappedValue = .newSession },
      retry: { connection.refreshSessions() })
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

  /// Deletes or leaves a session; its tabs close once it is gone.
  func removeSession(
    _ sessionID: String, _ operation: @escaping @MainActor (String) async -> Bool
  ) {
    let tabs = session.tabs
    Task {
      if await operation(sessionID) { tabs.removeSessions([sessionID]) }
    }
  }

  /// Renames through the session list, which reports a failure in `editError` (shown above).
  func rename(_ sessionID: String, to title: String) {
    let list = connection.sessionList
    Task {
      // The Boolean only repeats whether `editError` was set.
      _ = await list.rename(sessionID, to: title)
    }
  }

  /// Pins or archives through the session list (which reports failures in `editError`), and
  /// offers Undo for the change.
  func edit(_ change: SidebarUndo.Change, recordUndo: Bool = true) {
    let list = connection.sessionList
    let model = sidebarModel
    Task {
      var succeeded = true
      switch change {
      case .pin(let id, let pinned):
        succeeded = await list.setPinned(id, pinned)
      case .archive(let ids, let archived):
        for id in ids where succeeded {
          succeeded = await list.setArchived(id, archived)
        }
        if archived {
          // An archived session's tabs leave with it, its primary chat among them.
          session.tabs.removeSessions(Set(ids))
        }
      }
      if succeeded, recordUndo { model.undo = SidebarUndo(change: change) }
    }
  }

  /// Previous and next session in the sidebar's order.
  func navigation(from id: String) -> SessionCommandActions {
    let ids = connection.sessionList.visible.map(\.id)
    guard let index = ids.firstIndex(of: id) else { return SessionCommandActions() }
    let previous = index > ids.startIndex ? ids[index - 1] : nil
    let next = index + 1 < ids.endIndex ? ids[index + 1] : nil
    var actions = SessionCommandActions()
    if let previous {
      actions.previousSession = { showInPlace(previous) }
    }
    if let next {
      actions.nextSession = { showInPlace(next) }
    }
    return actions
  }

  func report() {
    connection.setView(sessionID: viewedSessionID, focused: isWindowFocused)
  }
}

// MARK: Fork from the sidebar

extension ConnectedServerView {
  var sidebarForkPresented: Binding<Bool> {
    let flow = sidebarModel.fork
    return Binding(get: { flow.viewState != nil }, set: { if !$0 { flow.cancel() } })
  }

  /// The fork opens as a chat tab, focused.
  var sidebarForkActions: ForkActions {
    let flow = sidebarModel.fork
    let tabs = session.tabs
    let list = connection.sessionList
    return ForkActions(
      fork: { agentID, directory, start in
        Task {
          await flow.fork(
            agentID: agentID, directory: directory, start: start,
            open: { tabs.open(.chat(sessionID: $0)) },
            report: { message in
              list.reportFailure(.InvalidState(message: message))
            })
        }
      },
      cancel: { flow.cancel() })
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
