import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// Asks before archiving sessions, or deleting a project, whose agents are still working.
struct RunningWorkPrompts: ViewModifier {
  let view: ConnectedServerView

  func body(content: Content) -> some View {
    let model = Bindable(view.sidebarModel)
    let view = view
    content
      .archiveRunningPrompt(model.archiveRunningRequest) { request in
        view.requestArchive(request.sessionIDs, archived: true, confirmedRunning: true)
      }
      .projectDeleteRunningPrompt(model.projectDeleteRunning) { project in
        Task { await view.connection.sessionList.deleteProject(ProjectSummary(project)) }
      }
  }
}

/// The sidebar and header row actions that open a dialog first: Archive, which may ask about
/// the sessions' git worktrees, and Share.
extension ConnectedServerView {
  /// Archives `sessionIDs` (or restores them): first confirming when agents are still working,
  /// as the web does, then asking whether to delete their worktrees as Settings › Git says.
  func requestArchive(_ sessionIDs: [String], archived: Bool, confirmedRunning: Bool = false) {
    guard archived else {
      edit(.archive(sessionIDs, false))
      return
    }
    let list = connection.sessionList
    let running = sessionIDs.count { Self.isWorking($0, list: list) }
    if running > 0, !confirmedRunning {
      sidebarModel.archiveRunningRequest = ArchiveRunningRequest(
        sessionIDs: sessionIDs, runningCount: running)
      return
    }
    let worktrees = Set(
      sessionIDs.filter { list.session($0)?.configuration?.gitBranch != nil })
    let decision = ArchiveWorktreeDecision.resolve(
      worktreeSessionIDs: worktrees,
      cleanupSupported: connection.pages?.offered?.archiveWorktreeCleanup == true,
      preference: UserDefaults.standard.string(forKey: GitPreferences.deleteWorktreesOnArchiveKey))
    switch decision {
    case .archive(let deleting):
      edit(.archive(sessionIDs, true), deletingWorktrees: deleting)
    case .ask(let worktreeIDs):
      sidebarModel.archiveRequest = ArchiveWorktreeRequest(
        sessionIDs: sessionIDs, worktreeSessionIDs: worktreeIDs)
    }
  }

  /// A session whose agent is still working, as the web's `isSessionWorking`: running, waiting
  /// on an approval, or with background work.
  static func isWorking(_ sessionID: String, list: SessionListStore) -> Bool {
    guard let session = list.session(sessionID) else { return false }
    return session.status == .running || session.status == .needsResponse
      || session.pendingRequests > 0 || session.backgroundWorkRunning
  }

  /// The answer to the worktree question; remembering saves it to Settings › Git.
  func archiveAnswered(_ request: ArchiveWorktreeRequest, delete: Bool, remember: Bool) {
    if remember {
      UserDefaults.standard.set(
        delete ? "true" : "false", forKey: GitPreferences.deleteWorktreesOnArchiveKey)
    }
    edit(
      .archive(request.sessionIDs, true),
      deletingWorktrees: delete ? request.worktreeSessionIDs : [])
  }

  /// Share for the viewer's own sessions on a server with sharing; `nil` hides it. A server that
  /// turned sharing off keeps it, disabled with ``shareUnavailableReason``, as the web does.
  var shareAction: (@MainActor (OmnigentUIComponents.SessionSummary) -> Void)? {
    guard ShareAdapter.offered(connection.pages?.offered) else { return nil }
    let connection = connection
    let model = sidebarModel
    return { summary in
      guard let store = connection.share(sessionID: summary.id) else { return }
      model.share = store
      Task { await store.load() }
    }
  }

  /// Why Share shows disabled: the server's admin turned sharing off.
  var shareUnavailableReason: String? {
    ShareAdapter.unavailableReason(connection.pages?.offered)
  }

  /// The Share sheet a sidebar row opened.
  var sidebarSharePresented: Binding<Bool> {
    let model = sidebarModel
    return Binding(get: { model.share != nil }, set: { if !$0 { model.share = nil } })
  }

  @ViewBuilder var sidebarShareSheet: some View {
    if let store = sidebarModel.share {
      ShareSheet(
        state: ShareAdapter.state(
          store,
          link: SidebarAdapter.webURL(
            server: connection.connectedServer, sessionID: store.sessionID)),
        actions: ShareAdapter.actions(store, openAutomation: openAutomationSharing)
      ) { sidebarModel.share = nil }
    }
  }
}
