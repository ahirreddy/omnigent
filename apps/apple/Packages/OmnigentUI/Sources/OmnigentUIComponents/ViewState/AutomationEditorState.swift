public import Foundation

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
  /// A Jira, Slack or GitHub trigger whose fields write the prompt (new automations only).
  public var trigger: AutomationTriggerDraft?

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
      && (trigger != nil || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      && !agentID.isEmpty
  }
}

/// A trigger's fields: what to watch, which items match, and what each session does.
nonisolated public struct AutomationTriggerDraft: Hashable, Sendable {
  /// The source's id (`jira`, `slack`, `github`).
  public var source: String
  /// One of the template's event ids.
  public var event: String
  /// Project keys, channels or `owner/repo`s, comma-separated.
  public var scope = ""
  /// The condition rows.
  public var conditions: [AutomationTriggerCondition] = []
  /// What each started session does with its item.
  public var instructions = ""
  /// Post the session link on the item.
  public var linkBack = true

  /// Creates the fields.
  public init(source: String, event: String) {
    self.source = source
    self.event = event
  }
}

/// One "and <field> <operator> <value>" row of a trigger.
nonisolated public struct AutomationTriggerCondition: Hashable, Sendable, Identifiable {
  /// Identifies the row while it is edited.
  public var id = UUID()
  /// A field id of the template.
  public var field: String
  /// An operator id of that field.
  public var operation: String
  /// The value; unused for valueless operators.
  public var value = ""

  /// Creates a row.
  public init(field: String, operation: String) {
    self.field = field
    self.operation = operation
  }
}

/// A source's trigger template, as the editor shows it.
nonisolated public struct AutomationTriggerTemplate: Hashable, Sendable {
  /// A comparison a field offers.
  public struct Operation: Hashable, Sendable, Identifiable {
    /// Id.
    public var id: String
    /// Label, e.g. "is unassigned".
    public var title: String
    /// The row has no value.
    public var isValueless: Bool

    /// Creates an operation.
    public init(id: String, title: String, isValueless: Bool) {
      self.id = id
      self.title = title
      self.isValueless = isValueless
    }
  }

  /// A field a row can test.
  public struct Field: Hashable, Sendable, Identifiable {
    /// Id.
    public var id: String
    /// Label.
    public var title: String
    /// Its comparisons, the default first.
    public var operations: [Operation]
    /// Placeholder.
    public var placeholder: String

    /// Creates a field.
    public init(id: String, title: String, operations: [Operation], placeholder: String) {
      self.id = id
      self.title = title
      self.operations = operations
      self.placeholder = placeholder
    }
  }

  /// Events (id, label), the default first.
  public var events: [AutomationOption]
  /// Words between the event and the scope, e.g. "in project".
  public var scopeLabel: String
  /// The scope's placeholder.
  public var scopePlaceholder: String
  /// Condition fields.
  public var fields: [Field]
  /// The instructions' placeholder.
  public var instructionsPlaceholder: String
  /// The link-back toggle's label.
  public var linkBackLabel: String
  /// The longest instructions, in characters.
  public var maxInstructions: Int

  /// Creates a template.
  public init(
    events: [AutomationOption], scopeLabel: String, scopePlaceholder: String, fields: [Field],
    instructionsPlaceholder: String, linkBackLabel: String, maxInstructions: Int
  ) {
    self.events = events
    self.scopeLabel = scopeLabel
    self.scopePlaceholder = scopePlaceholder
    self.fields = fields
    self.instructionsPlaceholder = instructionsPlaceholder
    self.linkBackLabel = linkBackLabel
    self.maxInstructions = maxInstructions
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

/// The model, effort and permission choices of an agent that takes them (Claude Code).
nonisolated public struct AutomationOverrideOptions: Hashable, Sendable {
  /// Models.
  public var models: [AutomationOption]
  /// Reasoning efforts.
  public var efforts: [AutomationOption]
  /// Permission modes.
  public var permissionModes: [AutomationOption]

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
