import OmnigentAppUI
import OmnigentStores
import OmnigentUIComponents

extension ServerWindowRoot {
  /// The Workflows page, asked to show the workflow `id`.
  static func workflow(_ id: String, in session: ServerSession) -> SidebarDestination {
    session.connection.workflows?.requestedWorkflowID = id
    return .workflows
  }
}
