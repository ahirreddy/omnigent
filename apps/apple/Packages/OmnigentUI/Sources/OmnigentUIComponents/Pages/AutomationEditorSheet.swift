public import SwiftUI

/// Creates or edits an automation in the web dialog's order: the name as the title; for a new
/// one, the trigger type and its schedule; the instructions or a trigger's form; where it runs,
/// its agent and permissions; then the optional Advanced settings (model and effort, session
/// continuity, MCP services, the schedule's end, workspace, project and cost limit). Both
/// platforms draw it as a native form: a sheet with Cancel and Create at its bottom right on a
/// Mac, and with them in the bar on iOS.
public struct AutomationEditorSheet: View {
  @Binding var draft: AutomationDraftState
  let context: AutomationEditorContext
  let save: @MainActor () -> Void
  let cancel: @MainActor () -> Void
  @State private var showsAdvanced = false

  /// Creates the sheet.
  /// - Parameters:
  ///   - draft: The fields.
  ///   - context: What the editor offers, server support and the save state.
  ///   - save: Save the fields.
  ///   - cancel: Close without saving.
  public init(
    draft: Binding<AutomationDraftState>, context: AutomationEditorContext,
    save: @escaping @MainActor () -> Void, cancel: @escaping @MainActor () -> Void
  ) {
    _draft = draft
    self.context = context
    self.save = save
    self.cancel = cancel
  }

  /// The form.
  public var body: some View {
    layout
      // As the web's: a problem whose fix lives under Advanced settings opens them.
      .onChange(of: advancedNeedsAttention, initial: true) { _, needsAttention in
        if needsAttention { showsAdvanced = true }
      }
  }

  private var layout: some View {
    AutomationEditorForm(editor: self, showsAdvanced: $showsAdvanced)
  }

  var title: String {
    if draft.sourceSessionID != nil, !context.isEditing {
      return "New automation from \u{201C}\(draft.sourceSessionTitle ?? "this session")\u{201D}"
    }
    return context.isEditing ? "Edit automation" : "New automation"
  }

  var saveTitle: String { context.isEditing ? "Save changes" : "Create" }

  /// Save follows ``saveBlockedReason``, so the button and what it says can't disagree.
  var canSave: Bool { !context.isSaving && saveBlockedReason == nil }

  /// Why Save is off: the first of ``saveBlockers``, which the disabled button explains.
  var saveBlockedReason: String? { saveBlockers.lazy.compactMap(\.self).first }

  /// What keeps Save off, in the form's order (web `submitBlockers`).
  var saveBlockers: [String?] {
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let missingInstructions =
      draft.trigger != nil
      ? context.triggerPrompt.isEmpty : draft.sourceSessionID == nil && prompt.isEmpty
    return [
      name.isEmpty ? "Enter a name in the field at the top." : nil,
      showsTypeRow && !isTrigger ? context.scheduleProblem : nil,
      missingInstructions
        ? (draft.trigger == nil
          ? "Add instructions." : "Fill in the trigger\u{2019}s required fields and instructions.")
        : nil,
      isTrigger && context.triggerScheduleUnsupported ? "Use a supported schedule." : nil,
      context.blocker,
      draft.agentID.isEmpty ? "Pick an agent." : nil,
      context.mcpProblem,
      scheduleInAdvanced ? context.scheduleProblem : nil,
      context.costLimitProblem,
    ]
  }

  /// A trigger polls on the server's interval, so its schedule stays out of the form.
  var isTrigger: Bool { draft.trigger != nil || draft.isTrigger }

  /// A new automation chooses its trigger type and schedule first; an edit or a session copy
  /// keeps its type, and its schedule moves under Advanced settings, as the web's.
  var showsTypeRow: Bool { !context.isEditing && draft.sourceSessionID == nil }

  /// An edit's schedule sits under Advanced settings, as the web's.
  var scheduleInAdvanced: Bool { !isTrigger && !showsTypeRow }

  var workspaceWithoutHost: Bool {
    !draft.runsInSandbox && draft.hostID.isEmpty
      && !draft.workspace.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// A problem whose explanation or fix is under Advanced settings.
  var advancedNeedsAttention: Bool {
    context.costLimitProblem != nil || workspaceWithoutHost
      || (context.mcpProblem != nil && context.mcpProblem != Self.loadingMcp)
      || (scheduleInAdvanced && context.scheduleProblem != nil)
  }

  private static let loadingMcp = "Loading MCP services\u{2026}"

  /// The schedule button's text, or that it needs attention, as the web's.
  var scheduleSummary: String {
    if context.scheduleProblem != nil { return "Needs attention" }
    if draft.schedule == nil, let kept = draft.keptRule { return kept }
    return context.describe(scheduleBinding.wrappedValue)
  }

  var scheduleBinding: Binding<ScheduleChoice> {
    Binding(
      get: { draft.schedule ?? ScheduleChoice() },
      set: { draft.schedule = $0 })
  }

  var promptLabel: String {
    if draft.sourceSessionID != nil { return "Additional instructions" }
    return "Instructions"
  }

  var promptPlaceholder: String {
    draft.sourceSessionID != nil
      ? "Optional. For example: Use this week\u{2019}s data."
      : "What should the agent do each run?"
  }
}

/// The trigger's form, the session a copy starts from, and what the type row says.
extension AutomationEditorSheet {
  /// The trigger's form, as form sections behind its Trigger and Instructions tabs.
  @ViewBuilder var triggerOrPrompt: some View {
    if let template = context.trigger, draft.trigger != nil {
      AutomationTriggerFields(
        trigger: triggerBinding, template: template, renderedPrompt: context.triggerPrompt,
        mcp: context.triggerMcp, usesMcp: usesTriggerMcp,
        switchEvent: context.switchTriggerEvent, editAsPrompt: editAsPrompt)
    }
  }

  private var triggerBinding: Binding<AutomationTriggerDraft> {
    Binding(
      get: { draft.trigger ?? AutomationTriggerDraft(source: "", event: "") },
      set: { draft.trigger = $0 })
  }

  private var usesTriggerMcp: Binding<Bool> {
    Binding(
      get: { context.triggerMcp.map { draft.mcpServices.contains($0.id) } ?? false },
      set: { uses in
        guard let id = context.triggerMcp?.id else { return }
        draft.mcpServices.removeAll { $0 == id }
        if uses { draft.mcpServices.append(id) }
      })
  }

  private func editAsPrompt() {
    draft.prompt = context.triggerPrompt
    draft.trigger = nil
  }

  var showsTriggerForm: Bool { context.trigger != nil && draft.trigger != nil }

  @ViewBuilder var startsFrom: some View {
    if let title = draft.sourceSessionTitle, draft.sourceSessionID != nil {
      VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
        Text("Starts from").fontWeight(.medium)
        Text(title).foregroundStyle(Theme.link)
          .accessibilityIdentifier("automation-source-session")
        Text(
          context.isEditing
            ? "Each run starts with a copy of this session\u{2019}s history."
            : "Each run starts with a copy of this session\u{2019}s history as of now."
        )
        .font(.callout).foregroundStyle(.secondary)
      }
    }
  }

  var triggersUnavailable: Bool {
    showsTypeRow && context.triggerTypes.isEmpty && draft.trigger == nil
  }
}
