import Foundation

/// The automation editor's fields. Empty ids mean "none".
nonisolated public struct AutomationDraftState: Hashable, Sendable {
  /// Name.
  public var name: String
  /// Prompt; replaced by the rendered trigger prompt while ``trigger`` is set.
  public var prompt: String
  /// The chosen agent's id.
  public var agentID: String
  /// The schedule; `nil` keeps a rule the editor cannot show (``keptRule``).
  public var schedule: ScheduleChoice?
  /// A rule kept as it is, described.
  public var keptRule: String?
  /// Continue one session across runs.
  public var continuesSession: Bool
  /// The pinned host's id.
  public var hostID = ""
  /// The pinned folder on that host; empty is its home.
  public var workspace = ""
  /// Run each time in a new sandbox instead of on a host.
  public var runsInSandbox = false
  /// The project's id.
  public var projectID = ""
  /// The model; empty is the agent's.
  public var model = ""
  /// The reasoning effort; empty is the agent's.
  public var effort = ""
  /// The permission mode; empty is the agent's.
  public var permissionMode = ""
  /// A continuing automation's next run starts a new session.
  public var startNewSession = false
  /// A trigger whose fields write the prompt: a new one, or a saved one whose header reopens
  /// its form.
  public var trigger: AutomationTriggerDraft?
  /// The generated template text around an older trigger's instructions, which ``prompt``
  /// then holds alone. Never shown; saving puts the instructions back into it.
  public var systemPrompt: String?
  /// It is a trigger, so its schedule is the polling interval and stays hidden.
  public var isTrigger = false
  /// The cost limit per run in USD as typed; empty is no limit.
  public var maxCost = ""
  /// The MCP services every run starts with.
  public var mcpServices: [String] = []
  /// Create it from this session: each run starts from a copy of it.
  public var sourceSessionID: String?
  /// That session's title, for the form.
  public var sourceSessionTitle: String?

  /// Creates the fields.
  public init(
    name: String = "", prompt: String = "", agentID: String = "",
    schedule: ScheduleChoice? = ScheduleChoice(), keptRule: String? = nil,
    continuesSession: Bool = false
  ) {
    self.name = name
    self.prompt = prompt
    self.agentID = agentID
    self.schedule = schedule
    self.keptRule = keptRule
    self.continuesSession = continuesSession
  }

  /// Whether the fields the form itself checks are filled; the context adds the server's rules.
  public var canSave: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (trigger != nil || sourceSessionID != nil
        || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      && !agentID.isEmpty
  }
}

/// Something the editor offers in a picker: an agent, host, project, model or mode.
nonisolated public struct AutomationOption: Hashable, Sendable, Identifiable {
  /// Id, the value saved.
  public var id: String
  /// Display name.
  public var name: String

  /// Creates an option.
  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

/// An MCP service a run can start with.
nonisolated public struct AutomationMcpOption: Hashable, Sendable, Identifiable {
  /// Id, the value saved.
  public var id: String
  /// Title.
  public var title: String
  /// The caller is signed in, so an unattended run can use it.
  public var isConnected: Bool

  /// Creates an option.
  public init(id: String, title: String, isConnected: Bool) {
    self.id = id
    self.title = title
    self.isConnected = isConnected
  }
}

/// The model, effort and permission choices of the chosen agent's harness.
nonisolated public struct AutomationOverrideOptions: Hashable, Sendable {
  /// Models.
  public var models: [AutomationOption]
  /// Reasoning efforts.
  public var efforts: [AutomationOption]
  /// Permission modes.
  public var permissionModes: [AutomationOption]
  /// The harness takes a model: models show even while the host lists none.
  public var takesModel = true
  /// Why no models are listed, e.g. "Connect your host to load models.".
  public var catalogMessage: String?

  /// Creates the options.
  public init(
    models: [AutomationOption], efforts: [AutomationOption], permissionModes: [AutomationOption]
  ) {
    self.models = models
    self.efforts = efforts
    self.permissionModes = permissionModes
  }
}

/// The editor's context: what it can offer, what the server supports, and the live checks.
public struct AutomationEditorContext {
  /// Agents to choose from.
  public var agents: [AutomationOption]
  /// The server can continue one session across runs.
  public var supportsSessionModes: Bool
  /// The schedule as text, from the core.
  public var describe: @MainActor (ScheduleChoice) -> String
  /// Editing an existing automation.
  public var isEditing: Bool
  /// The save is in flight.
  public var isSaving: Bool
  /// Why the save failed.
  public var error: String?
  /// Hosts to pin, offline ones marked.
  public var hosts: [AutomationOption] = []
  /// The sandbox option's label ("New Sandbox"); `nil` when the server has no sandboxes.
  public var sandboxLabel: String?
  /// The server can file an automation's sessions into a project.
  public var supportsProjects = false
  /// Projects to file sessions into.
  public var projects: [AutomationOption] = []
  /// The chosen agent's model, effort and permission choices; `nil` when it takes none.
  public var overrides: AutomationOverrideOptions?
  /// The server runs custom schedules and run-count endings (`automations_v2`).
  public var anchoredScheduling = false
  /// The minutes an Interval schedule may repeat every here.
  public var minuteRange: ClosedRange<Int> = 60...21_960
  /// Custom schedules offer minutes: the server and where runs go allow under an hour.
  public var offersMinutes = false
  /// Why the schedule can't be saved.
  public var scheduleProblem: String?
  /// What else blocks Save, e.g. "Pick a host before pinning a workspace.".
  public var blocker: String?
  /// The edited automation continues a session that a reset can replace.
  public var hasContinuingSession = false
  /// Said when an edit switches the agent.
  public var agentNote: String?
  /// The trigger template of ``AutomationDraftState/trigger``.
  public var trigger: AutomationTriggerTemplate?
  /// The rendered trigger prompt; empty until its fields are complete.
  public var triggerPrompt = ""
  /// Why the cost limit can't be saved.
  public var costLimitProblem: String?
  /// The MCP services runs can start with; none hides the picker.
  public var mcpServices: [AutomationMcpOption] = []
  /// Why the chosen MCP services can't be saved, e.g. one isn't signed in.
  public var mcpProblem: String?
  /// A trigger's own service in the MCP catalog, which it reads its items through.
  public var triggerMcp: AutomationMcpOption?
  /// Switches a trigger's event, clearing what the new event reads differently.
  public var switchTriggerEvent: (@MainActor (String) -> Void)?
  /// A trigger's hidden schedule doesn't fit where it runs now.
  public var triggerScheduleUnsupported = false
  /// Replaces a trigger's hidden schedule with one that fits.
  public var useSupportedTriggerSchedule: (@MainActor () -> Void)?
  /// The integrations a new automation can watch instead of a schedule (id, service name), as
  /// the web's Trigger type; empty where the server runs no triggers.
  public var triggerTypes: [AutomationOption] = []
  /// Switches a new automation to watch an integration by its id, or back to a schedule with
  /// `nil`, keeping each type's draft.
  public var switchTriggerType: (@MainActor (String?) -> Void)?

  /// Creates a context.
  public init(
    agents: [AutomationOption], supportsSessionModes: Bool,
    describe: @escaping @MainActor (ScheduleChoice) -> String, isEditing: Bool = false,
    isSaving: Bool = false, error: String? = nil
  ) {
    self.agents = agents
    self.supportsSessionModes = supportsSessionModes
    self.describe = describe
    self.isEditing = isEditing
    self.isSaving = isSaving
    self.error = error
  }
}
