public import SwiftUI

/// Creates or edits an automation in the web dialog's order: the name as the title; for a new
/// one, the trigger type and its schedule; the instructions or a trigger's form; where it runs,
/// its agent and permissions; then the optional Advanced settings (model and effort, session
/// continuity, MCP services, the schedule's end, workspace, project and cost limit). A Mac draws
/// it as the web's dialog; iOS draws the same order as a form.
public struct AutomationEditorSheet: View {
  @Binding var draft: AutomationDraftState
  let context: AutomationEditorContext
  let save: @MainActor () -> Void
  let cancel: @MainActor () -> Void
  @State private var showsAdvanced = false
  @State private var showsSchedule = false

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

  @ViewBuilder private var layout: some View {
    #if os(macOS)
      AutomationEditorDialog(
        editor: self, showsAdvanced: $showsAdvanced, showsSchedule: $showsSchedule)
    #else
      AutomationEditorForm(editor: self, showsAdvanced: $showsAdvanced)
    #endif
  }

  var title: String {
    if draft.sourceSessionID != nil, !context.isEditing {
      return "New automation from \u{201C}\(draft.sourceSessionTitle ?? "this session")\u{201D}"
    }
    return context.isEditing ? "Edit automation" : "New automation"
  }

  var saveTitle: String { context.isEditing ? "Save changes" : "Create" }

  var canSave: Bool {
    draft.canSave && !context.isSaving && context.blocker == nil
      && (isTrigger || context.scheduleProblem == nil)
      && !(isTrigger && context.triggerScheduleUnsupported)
      && context.costLimitProblem == nil && context.mcpProblem == nil
      && (draft.trigger == nil || !context.triggerPrompt.isEmpty)
  }

  /// A trigger polls on the server's interval, so its schedule stays out of the form.
  var isTrigger: Bool { draft.trigger != nil || draft.isTrigger }

  /// A new automation chooses its trigger type and schedule first; an edit or a session copy
  /// keeps its type, and its schedule moves under Advanced settings, as the web's.
  var showsTypeRow: Bool { !context.isEditing && draft.sourceSessionID == nil }

  /// An edit's schedule sits under Advanced settings on a Mac, as the web's; an iOS form
  /// keeps a section for it.
  var scheduleInAdvanced: Bool { !isTrigger && !showsTypeRow }

  var workspaceWithoutHost: Bool {
    !draft.runsInSandbox && draft.hostID.isEmpty
      && !draft.workspace.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// A problem whose explanation or fix is under Advanced settings.
  var advancedNeedsAttention: Bool {
    context.costLimitProblem != nil || workspaceWithoutHost
      || (context.mcpProblem != nil && context.mcpProblem != Self.loadingMcp)
      || (scheduleProblemIsAdvanced && context.scheduleProblem != nil)
  }

  private var scheduleProblemIsAdvanced: Bool {
    #if os(macOS)
      scheduleInAdvanced
    #else
      false
    #endif
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
  /// The trigger's form in the layout's style, or the instructions field.
  @ViewBuilder func triggerOrPrompt(builder: Bool) -> some View {
    if let template = context.trigger, draft.trigger != nil {
      if builder {
        AutomationTriggerBuilder(
          trigger: triggerBinding, template: template, renderedPrompt: context.triggerPrompt,
          mcp: context.triggerMcp, usesMcp: usesTriggerMcp,
          switchEvent: context.switchTriggerEvent, editAsPrompt: editAsPrompt)
      } else {
        AutomationTriggerFields(
          trigger: triggerBinding, template: template, renderedPrompt: context.triggerPrompt,
          mcp: context.triggerMcp, usesMcp: usesTriggerMcp,
          switchEvent: context.switchTriggerEvent, editAsPrompt: editAsPrompt)
      }
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
