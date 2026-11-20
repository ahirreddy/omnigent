import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Builds the automation editor's context from the store: hosts, projects, the harness's model,
/// effort and permission choices, MCP services, the cost limit, the trigger template and its
/// message budget, and the checks that block Save.
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
    /// Switches the trigger's event.
    var switchTriggerEvent: (@MainActor (String) -> Void)?
    /// Replaces a trigger's hidden schedule.
    var replaceSchedule: (@MainActor (ScheduleChoice) -> Void)?
    /// Switches a new automation between a schedule and an integration.
    var switchTriggerType: (@MainActor (String?) -> Void)?
    /// The caller's saved workflows, for the Workflow field.
    var workflows: [SavedWorkflow] = []
    /// Whether the pinned folder is a Git repository, for Random worktree.
    var worktreeCheck = AutomationWorktreeCheck.unavailable
    /// Lists a host's folders (by host id), for the Workspace row's Browse.
    var browseFolders:
      (@MainActor (String, String?) async -> Result<FolderListing, FolderBrowseError>)?
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

  /// Pi's thinking levels (the web's `PI_NATIVE_EFFORTS`).
  static let piEfforts =
    [AutomationOption(id: "none", name: "None"), AutomationOption(id: "minimal", name: "Minimal")]
    + claudeEfforts

  /// The harnesses whose model an automation can set (the web's `nativeAgentHasModelSettings`).
  static let modelHarnesses: Set<String> = [
    "claude-native", "codex-native", "pi-native", "devin-native",
  ]

  /// Modes that skip approval, which older servers refuse for an automation.
  static let approvalSkippingModes: Set<String> = [
    "bypassPermissions", "dontAsk", "full-access", "bypass", "yolo", "skip", "dangerous",
  ]

  /// The mode a new automation starts in, as nobody watches its turns (the web's
  /// `NEW_AUTOMATION_PERMISSION_MODES`), when the harness offers it.
  static func newAutomationPermission(_ agent: OmnigentCoreFFI.CreationAgent?) -> String {
    guard let agent else { return "" }
    let mode =
      switch agent.harnessId {
      case "claude-native": "auto"
      case "codex-native": "approve-for-me"
      default: ""
      }
    let offered = creationApprovalModeMenu(agent: agent)?.options.map(\.value) ?? []
    return offered.contains(mode) ? mode : ""
  }

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
    placement(&context, pages: pages, inputs: inputs)
    context.overrides = overrides(
      pages: pages, agentID: draft.agentID, hostID: draft.hostID,
      inSandbox: draft.runsInSandbox, model: draft.model)
    let limits = AutomationsMapping.limits(draft, offered: offered)
    schedule(&context, offered: offered, inputs: inputs, limits: limits)
    context.blocker =
      blocker(draft, isEditing: inputs.saved != nil) ?? sandboxBlocker(pages: pages, draft: draft)
    context.hasContinuingSession = inputs.saved?.sessionId != nil
    if let saved = inputs.saved, draft.agentID != saved.agentId {
      let name = context.agents.first { $0.id == draft.agentID }?.name ?? draft.agentID
      context.agentNote = "Future runs use \(name); past runs keep the agent they ran with"
    }
    context.costLimitProblem = costLimitProblem(text: draft.maxCost)
    workflow(&context, pages: pages, inputs: inputs)
    mcp(&context, pages: pages, draft: draft)
    if draft.trigger != nil || draft.isTrigger {
      triggerSchedule(&context, pages: pages, inputs: inputs)
    }
    // As the web's Trigger type: a new automation can watch an integration instead.
    if inputs.saved == nil, draft.sourceSessionID == nil, offered?.automationTriggers == true {
      context.triggerTypes = AutomationTriggerMapping.types
      context.switchTriggerType = inputs.switchTriggerType
    }
    if let trigger = draft.trigger, let source = AutomationTriggerMapping.source(trigger.source) {
      let budget = budget(pages: pages, draft: draft, saved: inputs.saved)
      context.trigger = AutomationTriggerMapping.template(source, budget: budget)
      context.triggerPrompt = triggerPrompt(
        pages: pages, draft: draft, saved: inputs.saved, sessionLink: inputs.sessionLink)
      context.switchTriggerEvent = inputs.switchTriggerEvent
      context.triggerMcp = triggerMcpService(source, services: context.mcpServices)
      workers(&context, pages: pages, inputs: inputs)
    }
    return context
  }

  /// The hosts, the sandbox option and the projects an automation can run with.
  private static func placement(
    _ context: inout AutomationEditorContext, pages: PagesStore, inputs: Inputs
  ) {
    let offered = pages.offered
    context.hosts = (pages.automationCatalog.value?.hosts ?? []).map {
      AutomationOption(
        id: $0.hostId, name: $0.status == "online" ? $0.name : "\($0.name) (offline)")
    }
    context.sandboxLabel = offered?.managedSandboxes == true ? "New Sandbox" : nil
    context.sandboxNotice = pages.automationCatalog.value?.automationSandboxNotice
    context.worktreeCheck = inputs.worktreeCheck
    if let browse = inputs.browseFolders, !inputs.draft.hostID.isEmpty {
      let hostID = inputs.draft.hostID
      context.browseWorkspace = { path in await browse(hostID, path) }
    }
    context.supportsProjects = offered?.automationProjects == true
    if context.supportsProjects {
      context.projects = (pages.automationProjects.value ?? []).compactMap { project in
        project.id.map { AutomationOption(id: $0, name: project.name) }
      }
    }
  }

  /// What the schedule offers here, and why it can't be saved.
  private static func schedule(
    _ context: inout AutomationEditorContext, offered: ServerPages?, inputs: Inputs,
    limits: ScheduleLimits
  ) {
    context.anchoredScheduling = offered?.automationsV2 == true
    context.ruleConversion = AutomationsMapping.ruleConversion
    let minimum = Int(minimumScheduleInterval(frequency: .minutely, limits: limits))
    context.minuteRange = minimum...Int(maximumScheduleInterval(frequency: .minutely))
    context.offersMinutes = minimum < 60
    context.scheduleProblem = AutomationsMapping.scheduleProblem(
      inputs.draft.schedule, saved: inputs.saved, anchored: context.anchoredScheduling,
      now: inputs.now, limits: limits)
  }

  /// The MCP picker, where the server takes runs' services and a trigger's saved workers
  /// don't own them, and why the choice can't be saved.
  private static func mcp(
    _ context: inout AutomationEditorContext, pages: PagesStore, draft: AutomationDraftState
  ) {
    guard showsMcpServices(pages.offered, draft: draft) else { return }
    let catalog = pages.automationMcpServices
    let services = (catalog.value ?? []).map {
      AutomationMcpOption(id: $0.id, title: $0.title, isConnected: $0.connected)
    }
    context.mcpServices = services
    let chosen = services.filter { draft.mcpServices.contains($0.id) }
    guard !draft.mcpServices.isEmpty else { return }
    if catalog == .loading || catalog == .idle {
      context.mcpProblem = "Loading MCP services\u{2026}"
    } else if catalog.error != nil {
      context.mcpProblem = "Could not load MCP services. Retry, or turn them off."
    } else if chosen.contains(where: { !$0.isConnected }) {
      context.mcpProblem = "Sign in to each selected MCP service, or turn it off."
    }
  }

  /// Whether the editor offers MCP services for `draft`.
  static func showsMcpServices(_ offered: ServerPages?, draft: AutomationDraftState) -> Bool {
    offered?.automationMcpServices == true && draft.trigger?.worker == nil
  }

  /// The catalog service a trigger reads its source through: by id (`slack`, or a namespaced
  /// `system.ai.slack`) or by title.
  static func triggerMcpService(_ source: TriggerSource, services: [AutomationMcpOption])
    -> AutomationMcpOption?
  {
    let id = AutomationTriggerMapping.id(source)
    let name = AutomationTriggerMapping.serviceName(source).lowercased()
    return services.first {
      $0.id == id || $0.id.hasSuffix(".\(id)") || $0.title.lowercased() == name
    }
  }

  /// A trigger's schedule is the polling interval; a saved one that doesn't fit where it runs
  /// now offers a replacement. A new one's is replaced as it saves.
  private static func triggerSchedule(
    _ context: inout AutomationEditorContext, pages: PagesStore, inputs: Inputs
  ) {
    guard context.scheduleProblem != nil, inputs.saved != nil else { return }
    let replacement = AutomationsMapping.triggerSchedule(
      pages.offered, continuesSession: inputs.draft.continuesSession,
      inSandbox: inputs.draft.runsInSandbox)
    context.triggerScheduleUnsupported = true
    if let replace = inputs.replaceSchedule {
      context.useSupportedTriggerSchedule = { replace(replacement) }
    }
  }

  /// How long a trigger's messages may be: the server's and polling host's limit, or a saved
  /// trigger's own while its target stays.
  static func budget(pages: PagesStore, draft: AutomationDraftState, saved: Automation?)
    -> TriggerMessageBudget
  {
    let target: TriggerPollingTarget
    if draft.runsInSandbox {
      target = .managedSandbox
    } else if let host = pages.automationCatalog.value?.hosts.first(where: {
      $0.hostId == draft.hostID
    }) {
      target = .host(
        name: host.name,
        longMessages: pages.longMessageHosts.value?.contains(host.hostId) == true)
    } else {
      target = .unknown
    }
    let sameTarget =
      saved.map {
        $0.runsInSandbox
          ? draft.runsInSandbox : !draft.runsInSandbox && draft.hostID == ($0.hostId ?? "")
      } ?? false
    let savedLimit =
      saved.flatMap {
        $0.isTrigger && sameTarget ? readTriggerMessageMaxChars(prompt: $0.prompt) : nil
      }
    return triggerMessageBudget(
      serverMaxChars: pages.offered?.sessionMessageMaxChars ?? 0, target: target,
      savedMaxChars: savedLimit)
  }

  /// The prompt a trigger saves, or empty until its fields are complete. An unchanged saved
  /// trigger keeps its prompt as it is.
  static func triggerPrompt(
    pages: PagesStore, draft: AutomationDraftState, saved: Automation?, sessionLink: String
  ) -> String {
    var draft = withWorkflowSessions(draft)
    // With a workflow, each match's instructions are the message that runs it.
    if let instructions = draft.trigger?.instructions, draft.workflow != nil {
      let message = AutomationsMapping.withWorkflow(
        instructions, draft: draft, skillPrefix: skillPrefix(pages, agentID: draft.agentID))
      draft.trigger?.instructions = message
    }
    let budget = budget(pages: pages, draft: draft, saved: saved)
    let options = overrides(
      pages: pages, agentID: draft.agentID, hostID: draft.hostID, inSandbox: draft.runsInSandbox)
    let config = AutomationTriggerMapping.config(
      draft, budget: budget, workerPermissionMode: workerPermissionMode(draft, pages: pages),
      sendsOverrides: options != nil)
    if let saved, let config, decodeTriggerPrompt(prompt: saved.prompt) == config,
      saved.name == draft.name
    {
      return saved.prompt
    }
    var context = AutomationTriggerMapping.context(draft, sessionLink: sessionLink, budget: budget)
    // Each match's session starts as a run of the workflow its instructions run.
    context.workflowIds = pages.offered?.sessionCreateWorkflowId == true
    return AutomationTriggerMapping.prompt(
      config, context: context, withHeader: pages.offered?.automationTriggerHeaders == true)
  }

  /// The permission a new trigger's workers start in: the automation's own, unless it skips
  /// approval, which the server refuses for a session an agent starts.
  static func workerPermissionMode(_ draft: AutomationDraftState, pages: PagesStore) -> String {
    let mode = draft.permissionMode
    guard pages.offered?.sessionCreatePermissionModes == true, !mode.isEmpty,
      !approvalSkippingModes.contains(mode)
    else { return "" }
    return mode
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

}

/// The harness's model, effort and permission choices.
extension AutomationEditorMapping {
  /// The model, effort and permission choices for `agentID`'s harness on `hostID` or a new
  /// sandbox, or `nil` when it takes none (the web's `useScheduledHarnessSettings`).
  static func overrides(
    pages: PagesStore, agentID: String, hostID: String, inSandbox: Bool, model: String = ""
  ) -> AutomationOverrideOptions? {
    guard let agent = pages.automationCatalog.value?.agents.first(where: { $0.id == agentID })
    else { return nil }
    let harness = agent.harnessId
    let offered = pages.offered
    let catalog = AutomationModelCatalog.resolve(
      pages: pages, agent: agent, hostID: hostID, inSandbox: inSandbox)
    let takesModel = catalog.takesModel
    let listed = catalog.listed
    var models = listed.map { AutomationOption(id: $0.value, name: $0.title) }
    if models.isEmpty, catalog.offersClaudeAliases { models = claudeModels }
    // Outside Claude Code, the harness settings need a server that stores them per harness.
    let permissionsOffered =
      harness == "claude-native" || offered?.automationHarnessSettings == true
    let skipsAccepted = offered?.automationApprovalSkippingModes == true
    let modes = permissionsOffered ? (creationApprovalModeMenu(agent: agent)?.options ?? []) : []
    let permissionModes = modes.filter {
      (skipsAccepted || !approvalSkippingModes.contains($0.value))
        && (harness == "claude-native" || $0.value != "default")
    }
    guard takesModel || !permissionModes.isEmpty else { return nil }
    var options = AutomationOverrideOptions(
      models: takesModel ? models : [],
      efforts: takesModel
        ? efforts(harness: catalog.effortHarness, models: listed, picked: model) : [],
      permissionModes: permissionModes.map { AutomationOption(id: $0.value, name: $0.title) })
    options.takesModel = takesModel
    if takesModel, models.isEmpty, catalog.blockedReason == nil {
      options.catalogMessage = catalog.emptyMessage
    }
    return options
  }

  /// Why `draft`'s harness can't run on a new sandbox at all, as its model preview says.
  static func sandboxBlocker(pages: PagesStore, draft: AutomationDraftState) -> String? {
    guard draft.runsInSandbox,
      let agent = pages.automationCatalog.value?.agents.first(where: { $0.id == draft.agentID })
    else { return nil }
    return AutomationModelCatalog.resolve(
      pages: pages, agent: agent, hostID: draft.hostID, inSandbox: true
    ).blockedReason
  }

  /// The web's `nativeEffortOptions`: Claude Code's and Pi's fixed ladders, else the efforts the
  /// host reports for the picked model (or its default).
  static func efforts(harness: String, models: [ModelChoice], picked: String)
    -> [AutomationOption]
  {
    switch harness {
    case "claude-native": return claudeEfforts
    case "pi-native": return piEfforts
    default: break
    }
    let model = models.first { $0.value == picked } ?? models.first { $0.isDefault == true }
    var seen = Set<String>()
    return (model?.supportedReasoningEfforts ?? []).compactMap { choice in
      let effort = choice.reasoningEffort
      guard !effort.isEmpty, seen.insert(effort).inserted else { return nil }
      return AutomationOption(
        id: effort, name: piEfforts.first { $0.id == effort }?.name ?? effort.capitalized)
    }
  }

  /// Whether a save of `draft` sends the model, effort and permission mode.
  static func sendsOverrides(pages: PagesStore, draft: AutomationDraftState) -> Bool {
    overrides(
      pages: pages, agentID: draft.agentID, hostID: draft.hostID, inSandbox: draft.runsInSandbox)
      != nil
  }

  /// Whether the agent's harness lists models for its host.
  static func takesModel(_ catalog: OmnigentCoreFFI.CreationCatalog?, agentID: String) -> Bool {
    catalog?.agents.first { $0.id == agentID }.map { modelHarnesses.contains($0.harnessId) }
      ?? false
  }
}
