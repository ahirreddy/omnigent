import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// A trigger's matching sessions (the web's worker harness settings): what their harness
/// offers, what a new trigger's take while they follow the polling session, and whether an
/// unset mode runs in the polling session's.
extension AutomationEditorMapping {
  @MainActor
  static func workers(_ context: inout AutomationEditorContext, pages: PagesStore, inputs: Inputs) {
    let draft = inputs.draft
    guard let trigger = draft.trigger else { return }
    let worker = trigger.worker
    let inSandbox =
      worker.map { $0.followsTarget ? draft.runsInSandbox : $0.inSandboxes } ?? draft.runsInSandbox
    guard
      var options = overrides(
        pages: pages, agentID: worker?.agentID ?? draft.agentID, hostID: draft.hostID,
        inSandbox: inSandbox, model: worker?.model ?? draft.model)
    else { return }
    // The server refuses a mode that skips approval for a session an agent starts.
    let modesApply = pages.offered?.sessionCreatePermissionModes == true
    let modes = options.permissionModes
    options.permissionModes =
      modesApply ? modes.filter { !approvalSkippingModes.contains($0.id) } : []
    context.workerOptions = options
    context.workerModesApply = modesApply
    let polling = draft.permissionMode
    context.workerInheritsPolling =
      modesApply && !polling.isEmpty && modes.contains { $0.id == polling }
    guard inputs.saved == nil else { return }
    let sends = context.overrides != nil
    var defaults = AutomationTriggerWorker(
      inSandboxes: draft.runsInSandbox, agentID: nil, model: sends ? draft.model : "",
      effort: sends ? draft.effort : "",
      permissionMode: workerPermissionMode(draft, pages: pages))
    defaults.followsTarget = true
    context.workerDefaults = defaults
  }
}

extension AutomationsMapping {
  /// Puts back `automation`'s model, effort and permission mode, as the editor opened with. A
  /// new trigger's matching sessions follow the polling session's again.
  static func restoreOverrides(_ draft: inout AutomationDraftState, from automation: Automation?) {
    draft.model = automation?.modelOverride ?? ""
    draft.effort = automation?.reasoningEffort ?? ""
    draft.permissionMode = automation?.permissionMode ?? ""
    if draft.trigger?.worker?.followsTarget == true { draft.trigger?.worker = nil }
  }
}
