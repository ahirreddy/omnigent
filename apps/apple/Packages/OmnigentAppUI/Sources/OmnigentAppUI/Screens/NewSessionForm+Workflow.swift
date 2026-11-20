import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// A saved workflow the new-session page runs or plans, and a run's review choice.
struct NewSessionWorkflow: Hashable {
  /// The run or planning chat.
  var launch: WorkflowLaunch
  /// A run starts with the user reviewing its plan.
  var reviewPlanFirst = false
  /// The planning prompt a host session keeps as its chat's draft rather than sending it.
  var plannerDraft: String?
}

/// The new-session page set to run a saved workflow or start its planning chat (web
/// `WorkflowSessionForm`): it picks where the agent runs as the page always does; a run's draft is
/// its optional additional instructions, and a planning chat starts with its prompt.
extension NewSessionForm {
  /// "Run “Triage flaky tests”", "Plan “Triage flaky tests”", else the page's own heading.
  var workflowHeading: String? {
    switch workflow?.launch {
    case .run(let target): "Run \u{201C}\(target.name)\u{201D}"
    case .plan(let target, _): "Plan \u{201C}\(target.name)\u{201D}"
    case nil: nil
    }
  }

  /// What a run does, or what a planning chat is for.
  var workflowSubtitle: String? {
    switch workflow?.launch {
    case .run(let target): target.description
    case .plan: "Starts a session where the agent drafts this workflow\u{2019}s plan with you."
    case nil: nil
    }
  }

  /// The composer's prompt while running a workflow.
  var workflowPlaceholder: String? {
    if case .run = workflow?.launch { return "Optional. Instructions to customize the workflow." }
    return nil
  }

  /// A run goes without additional instructions.
  var sendsWorkflowWithoutText: Bool {
    if case .run = workflow?.launch { return true }
    return false
  }

  /// Takes the launch the Workflows page handed over; a planning chat's prompt becomes the draft.
  /// - Returns: The draft to start from, if the launch has one.
  func takeWorkflowLaunch(_ creation: CreationStore) -> String? {
    guard let launch = creation.workflowLaunch else { return nil }
    creation.workflowLaunch = nil
    workflow = NewSessionWorkflow(launch: launch)
    if case .plan(_, let prompt) = launch { return prompt }
    return nil
  }

  /// The title and first message of the session `text` starts, filing a run under its workflow.
  /// A run sends its request with `text` as the details; a planning chat is named for its
  /// workflow, and on a host keeps `text` as its chat's draft for the user to send, as the web's
  /// planning chat does. A sandbox sends it once it is up.
  func workflowStart(text: String, selection: inout OmnigentCoreFFI.CreationSelection) -> (
    title: String, message: String
  ) {
    let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    switch workflow?.launch {
    case .run(let target):
      selection.workflowId = target.id
      let message = runSavedWorkflowPrompt(
        workflowId: target.id, workflowName: target.name, details: text,
        reviewPlanFirst: workflow?.reviewPlanFirst == true)
      return (typed, message)
    case .plan(let target, _):
      let title = typed.isEmpty ? "Plan workflow: \(target.name)" : typed
      guard !isSandbox else { return (title, text) }
      workflow?.plannerDraft = text
      return (title, "")
    case nil:
      return (typed, text)
    }
  }

  /// Leaves the workflow launch: the page starts ordinary sessions again.
  func clearWorkflow() {
    workflow = nil
  }
}

/// The page's workflow controls and what follows a planning chat's start.
extension NewSessionForm {
  /// The review choice and Cancel, while the page runs or plans a workflow.
  /// - Parameters:
  ///   - clearDraft: Empties the page's draft.
  ///   - openWorkflow: Opens the Workflows page on a workflow.
  /// - Returns: The controls; `nil` for an ordinary session.
  func workflowControls(
    clearDraft: @escaping @MainActor () -> Void, openWorkflow: (@MainActor (String) -> Void)?
  ) -> NewSessionWorkflowControls? {
    guard let launch = workflow?.launch else { return nil }
    let review: Binding<Bool>? =
      if case .run = launch {
        Binding(
          get: { self.workflow?.reviewPlanFirst == true },
          set: { self.workflow?.reviewPlanFirst = $0 })
      } else {
        nil
      }
    return NewSessionWorkflowControls(reviewPlanFirst: review) {
      self.clearWorkflow()
      clearDraft()
      openWorkflow?(launch.target.id)
    }
  }

  /// A planning chat that started is kept as its workflow's, whose page then opens with it, its
  /// prompt waiting in the chat's composer when it wasn't sent.
  /// - Returns: Whether `sessionID` is a planning chat.
  func planningStarted(
    _ sessionID: String, creation: CreationStore, workflows: WorkflowsStore?,
    openWorkflow: (@MainActor (String) -> Void)?
  ) -> Bool {
    guard case .plan(let target, _) = workflow?.launch, let workflows else { return false }
    if let draft = workflow?.plannerDraft { creation.leaveDraft(draft, inSession: sessionID) }
    Task {
      await workflows.setPlanningSession(target.id, sessionID: sessionID)
      openWorkflow?(target.id)
    }
    return true
  }
}
