import Foundation
import OmnigentAppUI
import OmnigentBrowser
import OmnigentDesktop
import OmnigentStores
import OmnigentUIComponents

extension ServerWindowRoot {
  /// The Workflows page, asked to show the workflow `id`.
  static func workflow(_ id: String, in session: ServerSession) -> SidebarDestination {
    session.connection.workflows?.requestedWorkflowID = id
    return .workflows
  }

  /// Opens Create Account with an invite link's token for the window's server.
  static func openInvite(_ invite: String, server: URL?, in session: ServerSession) {
    guard let server, let link = SceneLinkPlan.inviteLink(server: server, invite: invite)
    else { return }
    session.signIn.openInvite(link)
  }

  /// Edit > Find for a browser tab's page.
  static func find(_ page: BrowserTabModel) -> ServerWindowActions.Find {
    ServerWindowActions.Find(
      show: { page.showFindBar() },
      next: { Task { await page.findNext(forward: true) } },
      previous: { Task { await page.findNext(forward: false) } },
      useSelection: { Task { await page.useSelectionForFind() } })
  }

  /// View > Zoom for a browser tab's page.
  static func zoom(_ page: BrowserTabModel) -> ServerWindowActions.Zoom {
    ServerWindowActions.Zoom(
      reset: { page.resetZoom() }, zoomIn: { page.zoomIn() }, zoomOut: { page.zoomOut() })
  }
}
