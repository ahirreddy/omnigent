import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// A run of a saved workflow: the message it sends, and whether it needs a session of its own.
extension AutomationsMapping {
  /// A new automation that runs `workflow` as saved (web `lockedWorkflow`): named for it, with a
  /// new session each run, as a workflow's runs need.
  static func workflowDraft(
    _ workflow: SavedWorkflow, catalog: OmnigentCoreFFI.CreationCatalog?
  ) -> AutomationDraftState {
    var draft = newDraft(catalog: catalog)
    draft.name = workflow.name
    draft.continuesSession = false
    draft.workflow = AutomationOption(id: workflow.id, name: workflow.name)
    draft.workflowLocked = true
    return draft
  }

  /// A saved workflow's run reopens as its Workflow, with any additional instructions: the
  /// workflow goes in `draft`, and the instructions left are returned (`text` when it runs none).
  static func openWorkflow(_ text: String, in draft: inout AutomationDraftState) -> String {
    guard let run = parseSavedWorkflowMessage(text: text) else { return text }
    draft.workflow = AutomationOption(id: run.id, name: run.name)
    draft.workflowDetailsID = run.details.isEmpty ? nil : run.id
    return run.details
  }

  /// `text` as the message that runs the draft's workflow, which keeps it as additional
  /// instructions only while the form shows them (the web's `withWorkflow`).
  static func withWorkflow(_ text: String, draft: AutomationDraftState, skillPrefix: String)
    -> String
  {
    guard let workflow = draft.workflow else { return text }
    return savedWorkflowMessage(
      skillPrefix: skillPrefix, workflowId: workflow.id, workflowName: workflow.name,
      details: draft.showsInstructions ? text : "", reviewPlanFirst: false)
  }

  /// Whether each run follows a saved workflow, chosen or typed as its message, which needs a
  /// session of its own.
  static func runsSavedWorkflow(_ draft: AutomationDraftState) -> Bool {
    let instructions = draft.trigger?.instructions ?? draft.prompt
    return draft.workflow != nil || parseSavedWorkflowMessage(text: instructions) != nil
  }
}

/// The editor's Workflow field and what a workflow's runs need (the web's `WorkflowField`,
/// `withWorkflow` and `workflowNeedsNewSessions`).
extension AutomationEditorMapping {
  /// The saved workflows to choose from, and whether runs of one need new sessions.
  static func workflow(
    _ context: inout AutomationEditorContext, pages: PagesStore, inputs: Inputs
  ) {
    guard pages.offered?.workflows == true else { return }
    context.offersWorkflows = true
    context.workflows = inputs.workflows.map { AutomationOption(id: $0.id, name: $0.name) }
    context.workflowNeedsNewSessions = AutomationsMapping.runsSavedWorkflow(inputs.draft)
  }

  /// `draft` as it saves: each run of a saved workflow gets a session of its own, so it
  /// neither continues one session nor sends every match to one task session.
  static func withWorkflowSessions(_ draft: AutomationDraftState) -> AutomationDraftState {
    guard AutomationsMapping.runsSavedWorkflow(draft) else { return draft }
    var saving = draft
    saving.continuesSession = false
    saving.trigger?.taskSession = false
    return saving
  }

  /// How `agentID`'s harness invokes a skill, which a workflow's message starts with.
  static func skillPrefix(_ pages: PagesStore, agentID: String) -> String {
    let agent = pages.automationCatalog.value?.agents.first { $0.id == agentID }
    return skillInvocationPrefix(harness: agent?.harness)
  }
}
