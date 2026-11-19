import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The Workflows page over ``WorkflowsStore`` (web `WorkflowsPage`): the caller's workflows and
/// those shared with them, New workflow, and each row's Run, Create automation, Clone and Delete;
/// a row opens the workflow's page in place.
struct WorkflowsAdapter: View {
  let connection: ConnectionStore
  /// What the page opens elsewhere: sessions, automations and new runs.
  let routes: WorkflowRoutes
  @State private var search = ""
  @State private var detailID: String?
  @State private var deletePrompt: WorkflowDeletePrompt?

  var body: some View {
    if let store = connection.workflows {
      page(store)
        .task { await store.loadLists(sharing: offered?.workflowSharing == true) }
        // A new draft, a clone or a link lands on that workflow's page.
        .onChange(of: store.requestedWorkflowID, initial: true) { _, requested in
          guard let requested else { return }
          store.requestedWorkflowID = nil
          detailID = requested
        }
    } else {
      ContentUnavailableView("Workflows are unavailable", systemImage: "flowchart")
    }
  }

  private var offered: ServerPages? { connection.pages?.offered }

  @ViewBuilder private func page(_ store: WorkflowsStore) -> some View {
    if let detailID {
      WorkflowDetailAdapter(
        connection: connection, store: store, workflowID: detailID, routes: routes,
        back: { self.detailID = nil },
        open: { self.detailID = $0 }
      )
      .id(detailID)
    } else {
      WorkflowsView(
        state: WorkflowsMapping.list(
          store, offered: offered, search: search, deletePrompt: deletePrompt),
        actions: actions(store))
    }
  }

  private func actions(_ store: WorkflowsStore) -> WorkflowsActions {
    var actions = WorkflowsActions()
    let sharing = offered?.workflowSharing == true
    actions.search = { search = $0 }
    actions.create = { draft in
      switch await store.createDraft(name: draft.name, description: draft.description) {
      case .success: return nil
      case .failure(let error): return error.message
      }
    }
    actions.nameTaken = { workflowNameTaken(taken: WorkflowsMapping.takenNames(store), name: $0) }
    actions.open = { detailID = $0 }
    actions.run = { id in
      if let workflow = store.listed(id) { routes.run(workflow) }
    }
    if offered?.automations == true {
      actions.createAutomation = { id in
        if let workflow = store.listed(id) { routes.createAutomation(workflow) }
      }
    }
    actions.clone = { id in Task { await store.clone(id) } }
    actions.delete = { id in checkDelete(store, id: id) }
    actions.confirmDelete = { id in
      deletePrompt = nil
      Task { await store.delete(id) }
    }
    actions.retryDeleteCheck = {
      if let prompt = deletePrompt { checkDelete(store, id: prompt.id) }
    }
    actions.cancelDelete = { deletePrompt = nil }
    actions.retry = { Task { await store.loadOwned() } }
    actions.loadMore = { Task { await store.loadMoreOwned() } }
    if sharing {
      actions.retryShared = { Task { await store.loadShared() } }
      actions.loadMoreShared = { Task { await store.loadMoreShared() } }
    }
    actions.dismissError = { store.actionError = nil }
    return actions
  }

  /// Checks which automations run the workflow before Delete is offered, as the web's dialog
  /// does; automations off, there are none to check.
  private func checkDelete(_ store: WorkflowsStore, id: String) {
    let name = store.listed(id)?.name ?? ""
    guard let pages = connection.pages, offered?.automations == true else {
      deletePrompt = .ready(id: id, name: name, automations: [])
      return
    }
    deletePrompt = .checking(id: id, name: name)
    Task {
      await pages.loadAutomations()
      guard deletePrompt?.id == id else { return }
      if let automations = pages.automations.value {
        deletePrompt = .ready(
          id: id, name: name,
          automations: WorkflowsMapping.automationNames(automations, running: id))
      } else {
        deletePrompt = .checkFailed(id: id, name: name)
      }
    }
  }
}

/// Where the Workflows pages send the user beyond themselves.
struct WorkflowRoutes {
  /// Opens a session.
  var openSession: @MainActor (String) -> Void
  /// Opens a session's Tasks tab at a step.
  var openTask: @MainActor (String, String) -> Void
  /// Opens an automation's page.
  var openAutomation: @MainActor (String) -> Void
  /// Starts a run of a saved workflow: the new-session page, set to run it.
  var run: @MainActor (SavedWorkflow) -> Void
  /// Opens New automation with the workflow chosen.
  var createAutomation: @MainActor (SavedWorkflow) -> Void
  /// Starts the workflow's planning chat: the new-session page, set to plan it.
  var plan: @MainActor (WorkflowDetail) -> Void
  /// A session's chat for the planning panel.
  var chat: @MainActor (String) -> AnyView?
}
