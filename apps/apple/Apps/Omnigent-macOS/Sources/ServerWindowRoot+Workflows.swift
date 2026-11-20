import Foundation
import OmnigentAppUI
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
}
