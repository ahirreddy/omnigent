import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Builds the automation editor's context from the store: hosts, projects, the agent's model,
/// effort and permission choices, the trigger template, and the checks that block Save.
enum AutomationEditorMapping {
  /// One editor session's inputs besides the store.
  struct Inputs {
    /// The fields.
    var draft: AutomationDraftState
    /// The automation being edited.
    var saved: Automation?
    /// A session URL with the trigger placeholder id, for trigger link-backs.
    var sessionLink: String
    /// The save is in flight.
    var isSaving = false
    /// Why the save failed.
    var saveError: String?
    /// The current time, for end dates.
    var now = Date()
  }

  /// Claude Code's version-agnostic model aliases, offered when the host lists none (the web's
  /// `CLAUDE_NATIVE_MODELS`).
  static let claudeModels = [
    AutomationOption(id: "fable", name: "Fable"), AutomationOption(id: "opus", name: "Opus"),
    AutomationOption(id: "sonnet", name: "Sonnet"),
    AutomationOption(id: "sonnet_5", name: "Sonnet 5"),
    AutomationOption(id: "haiku", name: "Haiku"),
  ]

  /// Claude Code's reasoning efforts (the web's `CLAUDE_NATIVE_EFFORTS`).
  static let claudeEfforts = [
    AutomationOption(id: "low", name: "Low"), AutomationOption(id: "medium", name: "Medium"),
    AutomationOption(id: "high", name: "High"), AutomationOption(id: "xhigh", name: "xHigh"),
    AutomationOption(id: "max", name: "Max"),
  ]

  static func context(pages: PagesStore, inputs: Inputs) -> AutomationEditorContext {
    let offered = pages.offered
    let catalog = pages.automationCatalog.value
    let draft = inputs.draft
    var context = AutomationEditorContext(
      agents: AutomationsMapping.agents(catalog, selectedID: draft.agentID),
      supportsSessionModes: offered?.automationSessionModes == true,
      describe: { AutomationsMapping.describe($0) }, isEditing: inputs.saved != nil,
      isSaving: inputs.isSaving,
      error: inputs.saveError ?? pages.automationCatalog.error?.message)
    context.hosts = (catalog?.hosts ?? []).map {
      AutomationOption(
        id: $0.hostId, name: $0.status == "online" ? $0.name : "\($0.name) (offline)")
    }
    context.sandboxLabel = offered?.managedSandboxes == true ? "New Sandbox" : nil
    context.supportsProjects = offered?.automationProjects == true
    if context.supportsProjects {
      context.projects = (pages.automationProjects.value ?? []).compactMap { project in
        project.id.map { AutomationOption(id: $0, name: project.name) }
      }
    }
    context.overrides = overrides(pages: pages, agentID: draft.agentID, hostID: draft.hostID)
    context.anchoredScheduling = offered?.automationsV2 == true
    context.scheduleProblem = AutomationsMapping.scheduleProblem(
      draft.schedule, saved: inputs.saved, anchored: context.anchoredScheduling, now: inputs.now)
    context.blocker = blocker(draft, isEditing: inputs.saved != nil)
    context.hasContinuingSession = inputs.saved?.sessionId != nil
    if let saved = inputs.saved, draft.agentID != saved.agentId {
      let name = context.agents.first { $0.id == draft.agentID }?.name ?? draft.agentID
      context.agentNote = "Future runs use \(name); past runs keep the agent they ran with"
    }
    if let trigger = draft.trigger, let source = AutomationTriggerMapping.source(trigger.source) {
      context.trigger = AutomationTriggerMapping.template(source)
      context.triggerPrompt = AutomationTriggerMapping.prompt(
        draft, sessionLink: inputs.sessionLink, sendsOverrides: context.overrides != nil)
    }
    return context
  }

  /// What the core would refuse before sending, said in the form.
  static func blocker(_ draft: AutomationDraftState, isEditing: Bool) -> String? {
    if draft.runsInSandbox { return nil }
    let host = draft.hostID.trimmingCharacters(in: .whitespaces)
    if host.isEmpty, !draft.workspace.trimmingCharacters(in: .whitespaces).isEmpty {
      return "Pick a host before pinning a workspace."
    }
    if host.isEmpty, !isEditing { return "Pick the host this automation runs on." }
    return nil
  }

  /// The agent's catalog entry, when it takes a model, effort and permission mode (Claude Code,
  /// whose launch takes `--permission-mode`).
  static func overrideAgent(_ catalog: OmnigentCoreFFI.CreationCatalog?, agentID: String)
    -> OmnigentCoreFFI.CreationAgent?
  {
    catalog?.agents.first { $0.id == agentID && $0.harnessId == "claude-native" }
  }

  /// The model, effort and permission choices for `agentID`, or `nil` when it takes none.
  static func overrides(pages: PagesStore, agentID: String, hostID: String)
    -> AutomationOverrideOptions?
  {
    guard let agent = overrideAgent(pages.automationCatalog.value, agentID: agentID) else {
      return nil
    }
    let key = PagesStore.modelsKey(agentID: agentID, hostID: hostID)
    let listed = (pages.automationModels[key]?.value ?? []).filter { $0.hidden != true }.map {
      AutomationOption(id: $0.id, name: $0.displayName ?? $0.id)
    }
    let modes = creationApprovalModeMenu(agent: agent)?.options ?? []
    return AutomationOverrideOptions(
      models: listed.isEmpty ? claudeModels : listed, efforts: claudeEfforts,
      permissionModes: modes.map { AutomationOption(id: $0.value, name: $0.title) })
  }

  /// Whether a save of `draft` sends the model, effort and permission mode.
  static func sendsOverrides(_ catalog: OmnigentCoreFFI.CreationCatalog?, agentID: String) -> Bool {
    overrideAgent(catalog, agentID: agentID) != nil
  }
}
