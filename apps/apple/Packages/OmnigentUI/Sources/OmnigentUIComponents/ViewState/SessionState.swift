// Mirrors of the core's session records (`omnigent-ffi` `transcript.rs`).

// Optional booleans mirror the core's `Option<bool>`: `nil` means the server has not reported
// the value, which the UI shows as "Unknown", never as false.
// swiftlint:disable discouraged_optional_boolean

/// The session's turn status.
nonisolated public enum TurnStatus: String, Hashable, Sendable, CaseIterable {
  /// Nothing is running.
  case idle
  /// A turn or background work is in progress.
  case running
  /// A decision is pending.
  case needsResponse
}

/// A configuration value that tells "not reported" from an explicit harness default.
nonisolated public enum ReportedValue: Hashable, Sendable {
  /// The server has not said.
  case notReported
  /// The server reported `null`: the harness default applies.
  case harnessDefault
  /// The server reported a value.
  case value(value: String)

  /// The value, when one was reported.
  public var reportedValue: String? {
    if case .value(let value) = self { return value }
    return nil
  }
}

/// One native model-picker row.
nonisolated public struct ModelOption: Hashable, Sendable, Identifiable {
  /// Model id.
  public var id: String
  /// Provider model name.
  public var model: String?
  /// Display name; fall back to `id`.
  public var displayName: String?
  /// Default reasoning effort.
  public var defaultReasoningEffort: String?
  /// Supported reasoning efforts.
  public var supportedReasoningEfforts: [String]
  /// The default model.
  public var isDefault: Bool
  /// Hidden from the picker.
  public var hidden: Bool

  /// Creates a model option.
  /// - Parameters:
  ///   - id: Model id.
  ///   - model: Provider model name.
  ///   - displayName: Display name.
  ///   - defaultReasoningEffort: Default effort.
  ///   - supportedReasoningEfforts: Supported efforts.
  ///   - isDefault: The default model.
  ///   - hidden: Hidden from the picker.
  public init(
    id: String, model: String? = nil, displayName: String? = nil,
    defaultReasoningEffort: String? = nil, supportedReasoningEfforts: [String] = [],
    isDefault: Bool = false, hidden: Bool = false
  ) {
    self.id = id
    self.model = model
    self.displayName = displayName
    self.defaultReasoningEffort = defaultReasoningEffort
    self.supportedReasoningEfforts = supportedReasoningEfforts
    self.isDefault = isDefault
    self.hidden = hidden
  }

  /// The label a picker shows.
  public var label: String { displayName ?? model ?? id }
}

/// The session's harness, model and execution settings, as last reported.
nonisolated public struct SessionSettings: Hashable, Sendable {
  /// The agent.
  public var agentId: String?
  /// The harness, for example `codex-native`.
  public var harness: String?
  /// The `omnigent.wrapper` label.
  public var wrapper: String?
  /// The model override.
  public var modelOverride: ReportedValue
  /// The agent's base model.
  public var baseModel: String?
  /// The reasoning effort.
  public var reasoningEffort: ReportedValue
  /// Native model-picker rows.
  public var modelOptions: [ModelOption]
  /// The bound host.
  public var hostId: String?
  /// The host is online.
  public var hostOnline: Bool?
  /// The runner is online.
  public var runnerOnline: Bool?
  /// A runner is bound.
  public var runnerBound: Bool?
  /// A managed host can be woken.
  public var hostResumable: Bool?
  /// The parent session of a child.
  public var parentId: String?
  /// `cost_control_mode_override`.
  public var routingMode: String?

  /// Creates settings.
  /// - Parameters:
  ///   - agentId: Agent id.
  ///   - harness: Harness id.
  ///   - wrapper: Wrapper label.
  ///   - modelOverride: Model override.
  ///   - baseModel: Base model.
  ///   - reasoningEffort: Reasoning effort.
  ///   - modelOptions: Model picker rows.
  ///   - hostId: Host id.
  ///   - hostOnline: Host online.
  ///   - runnerOnline: Runner online.
  ///   - runnerBound: Runner bound.
  ///   - hostResumable: Host can be woken.
  ///   - parentId: Parent session.
  ///   - routingMode: Routing mode.
  public init(
    agentId: String? = nil, harness: String? = nil, wrapper: String? = nil,
    modelOverride: ReportedValue = .notReported, baseModel: String? = nil,
    reasoningEffort: ReportedValue = .notReported, modelOptions: [ModelOption] = [],
    hostId: String? = nil, hostOnline: Bool? = nil, runnerOnline: Bool? = nil,
    runnerBound: Bool? = nil, hostResumable: Bool? = nil, parentId: String? = nil,
    routingMode: String? = nil
  ) {
    self.agentId = agentId
    self.harness = harness
    self.wrapper = wrapper
    self.modelOverride = modelOverride
    self.baseModel = baseModel
    self.reasoningEffort = reasoningEffort
    self.modelOptions = modelOptions
    self.hostId = hostId
    self.hostOnline = hostOnline
    self.runnerOnline = runnerOnline
    self.runnerBound = runnerBound
    self.hostResumable = hostResumable
    self.parentId = parentId
    self.routingMode = routingMode
  }

  /// The model label: the override, else the base model, else "Default model".
  public var modelLabel: String {
    if let value = modelOverride.reportedValue {
      return modelOptions.first { $0.id == value || $0.model == value }?.label ?? value
    }
    return baseModel ?? "Default model"
  }
}

/// Session metadata shown with the conversation.
nonisolated public struct SessionHeader: Hashable, Sendable, Identifiable {
  /// The session id.
  public var id: String
  /// Title.
  public var title: String
  /// Turn status.
  public var status: TurnStatus
  /// The caller cannot write to the session.
  public var readOnly: Bool
  /// Archived.
  public var archived: Bool
  /// The caller's permission level.
  public var permissionLevel: Int64?
  /// A readable failure of the last turn.
  public var failureMessage: String?
  /// Settings, once reported.
  public var settings: SessionSettings?

  /// Creates a header.
  /// - Parameters:
  ///   - id: Session id.
  ///   - title: Title.
  ///   - status: Turn status.
  ///   - readOnly: Read only.
  ///   - archived: Archived.
  ///   - permissionLevel: Permission level.
  ///   - failureMessage: Last failure.
  ///   - settings: Settings.
  public init(
    id: String, title: String, status: TurnStatus = .idle, readOnly: Bool = false,
    archived: Bool = false, permissionLevel: Int64? = nil, failureMessage: String? = nil,
    settings: SessionSettings? = nil
  ) {
    self.id = id
    self.title = title
    self.status = status
    self.readOnly = readOnly
    self.archived = archived
    self.permissionLevel = permissionLevel
    self.failureMessage = failureMessage
    self.settings = settings
  }
}

/// One session-metadata section (usage, plan, children, changed files, ...).
nonisolated public struct EventSection: Hashable, Sendable, Identifiable {
  /// Stable id, for example `usage`, `todos`, `presence`, `child-<id>` or `files-<env>`.
  public var id: String
  /// Heading.
  public var title: String
  /// One line.
  public var summary: String
  /// Detail blocks.
  public var details: [DetailSection]
  /// A session the section links to.
  public var sessionId: String?

  /// Creates a section.
  /// - Parameters:
  ///   - id: Stable id.
  ///   - title: Heading.
  ///   - summary: One line.
  ///   - details: Detail blocks.
  ///   - sessionId: Linked session.
  public init(
    id: String, title: String, summary: String, details: [DetailSection] = [],
    sessionId: String? = nil
  ) {
    self.id = id
    self.title = title
    self.summary = summary
    self.details = details
    self.sessionId = sessionId
  }
}

// swiftlint:enable discouraged_optional_boolean
