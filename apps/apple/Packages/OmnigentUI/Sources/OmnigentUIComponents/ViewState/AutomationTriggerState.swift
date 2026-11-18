public import Foundation

/// A trigger's fields: what to watch, which items match, and what each session does.
nonisolated public struct AutomationTriggerDraft: Hashable, Sendable {
  /// The source's id (`jira`, `slack`, `github`, `linear`, `pagerduty`).
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
  /// How the scope matches (`is`, `in`, `contains`); `nil` infers it from the values.
  public var scopeOperator: String?
  /// The event's inline value, e.g. a review request's reviewer.
  public var target: String?
  /// The owner set link-back, so switching events keeps it.
  public var linkBackTouched = false
  /// Every match goes to one task session (kept from a saved trigger).
  public var taskSession = false
  /// A saved trigger's workers, kept as they are; `nil` follows the automation.
  public var worker: AutomationTriggerWorker?

  /// Creates the fields.
  public init(source: String, event: String) {
    self.source = source
    self.event = event
  }
}

/// A saved trigger's worker settings, which this form keeps rather than edits.
nonisolated public struct AutomationTriggerWorker: Hashable, Sendable {
  /// Workers start in their own sandboxes.
  public var inSandboxes: Bool
  /// Their agent; `nil` is the polling session's.
  public var agentID: String?
  /// Their model; empty is the agent's.
  public var model: String
  /// Their effort; empty is the agent's.
  public var effort: String
  /// Their permission mode; empty is the agent's.
  public var permissionMode: String

  /// Creates the settings.
  public init(
    inSandboxes: Bool, agentID: String?, model: String, effort: String, permissionMode: String
  ) {
    self.inSandboxes = inSandboxes
    self.agentID = agentID
    self.model = model
    self.effort = effort
    self.permissionMode = permissionMode
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
  /// The field a custom-field row compares, e.g. `ES Component`.
  public var name: String?

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
    /// The placeholder of the field name a custom-field row compares.
    public var namePlaceholder: String?

    /// Creates a field.
    public init(
      id: String, title: String, operations: [Operation], placeholder: String,
      namePlaceholder: String? = nil
    ) {
      self.id = id
      self.title = title
      self.operations = operations
      self.placeholder = placeholder
      self.namePlaceholder = namePlaceholder
    }
  }

  /// What an event changes in the form.
  public struct Event: Hashable, Sendable {
    /// The help text above the builder.
    public var description: String
    /// The scope's label, e.g. "sender".
    public var scopeLabel: String
    /// The scope's placeholder.
    public var scopePlaceholder: String
    /// `#`, `@` or empty, shown before the scope.
    public var scopePrefix: String
    /// The scope lists the members of one group.
    public var isGroup: Bool
    /// Condition fields it doesn't offer.
    public var hiddenFields: [String]
    /// The inline value it names: word, label, placeholder, whether required.
    public var target: Target?

    /// Creates an event.
    public init(
      description: String, scopeLabel: String, scopePlaceholder: String, scopePrefix: String = "",
      isGroup: Bool = false, hiddenFields: [String] = [], target: Target? = nil
    ) {
      self.description = description
      self.scopeLabel = scopeLabel
      self.scopePlaceholder = scopePlaceholder
      self.scopePrefix = scopePrefix
      self.isGroup = isGroup
      self.hiddenFields = hiddenFields
      self.target = target
    }
  }

  /// An event's inline value, e.g. "Review requested from [me]".
  public struct Target: Hashable, Sendable {
    /// Shown before the input, e.g. "from".
    public var word: String
    /// Label.
    public var label: String
    /// Placeholder.
    public var placeholder: String
    /// Said when a required value is missing or invalid.
    public var hint: String?
    /// The value is required.
    public var isRequired: Bool

    /// Creates a target.
    public init(word: String, label: String, placeholder: String, hint: String?, isRequired: Bool) {
      self.word = word
      self.label = label
      self.placeholder = placeholder
      self.hint = hint
      self.isRequired = isRequired
    }
  }

  /// Events (id, label), the default first.
  public var events: [AutomationOption]
  /// What each event changes, by id.
  public var eventDetails: [String: Event] = [:]
  /// The scope's operators (id, label), e.g. equals and in.
  public var scopeOperators: [AutomationOption] = []
  /// What to update for the full instruction budget; `nil` when it applies.
  public var budgetHint: String?
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
