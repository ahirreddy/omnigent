import OmnigentCoreFFI
import OmnigentPlatform
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

// MARK: Workflows

extension ConnectedServerView {
  /// The Workflows page and a workflow's page.
  var workflowsPage: some View {
    WorkflowsAdapter(connection: connection, routes: workflowRoutes)
  }

  /// Where the Workflows pages lead: sessions, a session's task, automations, and the
  /// new-session page set to run or plan a workflow.
  var workflowRoutes: WorkflowRoutes {
    let selection = selectionBinding
    let connection = connection
    let tabs = session.tabs
    return WorkflowRoutes(
      openSession: { selection.wrappedValue = .session($0) },
      openTask: { sessionID, stepID in
        connection.tasks(sessionID)?.taskToShow = stepID
        selection.wrappedValue = .session(sessionID)
      },
      openAutomation: { openAutomation($0) },
      run: { workflow in
        connection.creation()?.workflowLaunch = .run(
          WorkflowLaunchTarget(
            id: workflow.id, name: workflow.name, description: workflow.description))
        selection.wrappedValue = .newSession
      },
      createAutomation: { workflow in
        connection.workflows?.pendingAutomation = workflow
        selection.wrappedValue = .automations
      },
      plan: { detail in
        connection.creation()?.workflowLaunch = .plan(
          WorkflowLaunchTarget(
            id: detail.workflow.id, name: detail.workflow.name,
            description: detail.workflow.description),
          prompt: editWorkflowPlanPrompt(workflow: detail))
        selection.wrappedValue = .newSession
      },
      chat: { id in
        AnyView(
          plannerChat(id).onAppear { tabs.quickViewSessionID = id }
            .onDisappear { if tabs.quickViewSessionID == id { tabs.quickViewSessionID = nil } })
      })
  }

  /// The saved workflows a chat's Run a workflow offers, where the server keeps them.
  var workflowsReach: TasksAdapter.Workflows? {
    let offered = connection.pages?.offered
    guard offered?.workflows == true, let store = connection.workflows else { return nil }
    return TasksAdapter.Workflows(store: store, sharing: offered?.workflowSharing == true)
  }

  /// The planning session's chat beside a workflow, once its conversation is open.
  @ViewBuilder private func plannerChat(_ id: String) -> some View {
    if let chat = chat(id) {
      chat.id(id)
    } else {
      LoadingCaption(title: "Opening the session\u{2026}")
    }
  }
}
