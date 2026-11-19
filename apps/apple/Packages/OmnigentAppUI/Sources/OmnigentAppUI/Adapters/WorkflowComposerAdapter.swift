import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Run a workflow and Save as workflow in a session (web `ChatPage`'s workflow dialogs): where
/// the agent has the skill and the server keeps workflows, the saved ones to pick and the message
/// each sends.
enum WorkflowComposerAdapter {
  /// Run a workflow over `store`'s saved workflows; `nil` where it isn't offered.
  /// - Parameters:
  ///   - composer: The session's composer, whose skills and harness decide it.
  ///   - store: The saved workflows, where the server keeps them.
  ///   - sharing: The server shares workflows, so those shared with the caller list too.
  ///   - blockedReason: Why the session can't take a message now.
  /// - Returns: The source, or `nil` without the skill or the store.
  static func runSource(
    composer: ComposerStore, store: WorkflowsStore?, sharing: Bool,
    blockedReason: @escaping @MainActor () -> String?
  ) -> WorkflowRunSource? {
    guard let store, workflowSkills(skillNames: composer.skills.map(\.name)).runs else {
      return nil
    }
    let prefix = skillInvocationPrefix(harness: composer.configuration?.harness)
    return WorkflowRunSource(
      choices: { choices(store, search: $0) },
      loadMore: {
        Task {
          if store.ownedCursor != nil {
            await store.loadMoreOwned()
          } else {
            await store.loadMoreShared()
          }
        }
      },
      refresh: { Task { await store.loadLists(sharing: sharing) } },
      blockedReason: blockedReason,
      run: { request in
        let message = runMessage(request, prefix: prefix, store: store)
        Task { await composer.sendWorkflowMessage(message) }
      },
      draft: { composer.text })
  }

  /// The saved workflows with a plan whose name matches, the caller's then those shared.
  static func choices(_ store: WorkflowsStore, search: String) -> RunWorkflowChoices {
    let all = (store.owned.value ?? []) + (store.shared.value ?? [])
    var choices = RunWorkflowChoices()
    choices.rows = runnableWorkflows(workflows: all, query: search).map {
      WorkflowsMapping.row($0)
    }
    choices.hasAny = !runnableWorkflows(workflows: all, query: "").isEmpty
    choices.hasMore = store.ownedCursor != nil || store.sharedCursor != nil
    choices.isLoadingMore = store.isLoadingMoreOwned || store.isLoadingMoreShared
    return choices
  }

  /// What a run sends: a saved workflow by id with the run's details, or a described one.
  static func runMessage(_ request: RunWorkflowRequest, prefix: String, store: WorkflowsStore)
    -> String
  {
    if let id = request.savedWorkflowID, let workflow = store.listed(id) {
      return savedWorkflowMessage(
        skillPrefix: prefix, workflowId: id, workflowName: workflow.name,
        details: request.description, reviewPlanFirst: request.reviewPlanFirst)
    }
    return workflowMessage(
      skillPrefix: prefix, description: request.description,
      reviewPlanFirst: request.reviewPlanFirst)
  }

  /// Save as workflow for the Tasks tab's plan; `nil` where it isn't offered.
  /// - Parameters:
  ///   - composer: The session's composer.
  ///   - offered: The server keeps workflows.
  ///   - planName: The plan's name, which the sheet starts from.
  ///   - workflowID: The saved workflow the plan already follows, which disables it.
  ///   - blockedReason: Why the session can't take a message now.
  /// - Returns: The source, or `nil` without the skill or workflows.
  static func saveSource(
    composer: ComposerStore, offered: Bool, planName: String?, workflowID: String?,
    blockedReason: @escaping @MainActor () -> String?
  ) -> WorkflowSaveSource? {
    guard offered, workflowSkills(skillNames: composer.skills.map(\.name)).saves else {
      return nil
    }
    let prefix = skillInvocationPrefix(harness: composer.configuration?.harness)
    return WorkflowSaveSource(
      initialName: planName ?? "",
      disabledReason: workflowID == nil
        ? nil : "Already saved as a workflow. Open the workflow to edit it.",
      blockedReason: blockedReason,
      save: { name in
        Task {
          await composer.sendWorkflowMessage(saveWorkflowMessage(skillPrefix: prefix, name: name))
        }
      })
  }
}
