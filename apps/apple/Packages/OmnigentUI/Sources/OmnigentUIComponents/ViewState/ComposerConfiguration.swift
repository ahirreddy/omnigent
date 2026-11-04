import Foundation

/// Where the agent picker lists an agent, as the web's new-session picker groups them.
nonisolated public enum AgentPickerGroup: Hashable, Sendable {
  /// "Harnesses", inline (Claude Code, Cursor, Codex).
  case harness
  /// "Harnesses", under "Other…".
  case otherHarness
  /// "Agents", inline (built-in composed agents).
  case agent
  /// "Agents", under "Other…" (custom and the user's own agents).
  case custom
}

/// The agent, model and reasoning picker the composer shows, in that order. Defaults are always
/// shown as what they resolve to ("Default (GPT-5.2 Codex)"), or "Agent default" when unknown.
nonisolated public struct ComposerConfiguration: Hashable, Sendable {
  /// The current harness, for its glyph.
  public var harness: String?
  /// The agent's display name, for example "Codex".
  public var agentName: String?
  /// Harnesses the session may switch to; empty hides the agent section.
  public var harnessChoices: [HarnessChoice]
  /// The selected agent id among ``harnessChoices``.
  public var selectedAgentId: String?
  /// Picker rows for the selected agent. Hidden rows are not shown.
  public var modelOptions: [ModelOption]
  /// The selected model id; `nil` is the agent's default.
  public var selectedModelId: String?
  /// The model the agent runs when none is chosen, when the server reports it.
  public var baseModel: String?
  /// The selected reasoning effort; `nil` is the model's default.
  public var selectedEffort: String?
  /// The configuration is being applied.
  public var isApplying: Bool
  /// Why the model catalog could not load, if it failed.
  public var errorMessage: String?
  /// Picker groups by agent id; empty lists the agents flat under "Agent".
  public var agentGroups: [String: AgentPickerGroup] = [:]

  /// Creates a configuration.
  /// - Parameters:
  ///   - harness: Harness id.
  ///   - agentName: Agent display name.
  ///   - harnessChoices: Switchable harnesses.
  ///   - selectedAgentId: Selected agent.
  ///   - modelOptions: Model rows.
  ///   - selectedModelId: Selected model.
  ///   - baseModel: The default model, when reported.
  ///   - selectedEffort: Selected effort.
  ///   - isApplying: Being applied.
  ///   - errorMessage: Catalog error.
  public init(
    harness: String? = nil, agentName: String? = nil, harnessChoices: [HarnessChoice] = [],
    selectedAgentId: String? = nil, modelOptions: [ModelOption] = [],
    selectedModelId: String? = nil, baseModel: String? = nil, selectedEffort: String? = nil,
    isApplying: Bool = false, errorMessage: String? = nil
  ) {
    self.harness = harness
    self.agentName = agentName
    self.harnessChoices = harnessChoices
    self.selectedAgentId = selectedAgentId
    self.modelOptions = modelOptions
    self.selectedModelId = selectedModelId
    self.baseModel = baseModel
    self.selectedEffort = selectedEffort
    self.isApplying = isApplying
    self.errorMessage = errorMessage
  }

  /// The selected agent row.
  public var selectedAgent: HarnessChoice? {
    guard let selectedAgentId else { return nil }
    return harnessChoices.first { $0.id == selectedAgentId }
  }

  /// The agent's name: the reported name, else the selected row's, else the harness's label.
  public var agentTitle: String {
    agentName ?? selectedAgent?.name ?? HarnessAppearance(harness: harness).label
  }

  /// Models the picker offers.
  public var visibleModels: [ModelOption] { modelOptions.filter { !$0.hidden } }

  /// The selected model row.
  public var selectedModel: ModelOption? {
    guard let selectedModelId else { return nil }
    return modelOptions.first { $0.id == selectedModelId }
  }

  /// The row the agent marks as its default.
  public var defaultModel: ModelOption? { modelOptions.first(where: \.isDefault) }

  /// What "Default" resolves to: the default row's name, else the reported base model (by its
  /// row's name when there is one). `nil` when unknown.
  public var resolvedDefaultModelName: String? {
    if let defaultModel { return defaultModel.label }
    guard let baseModel, !baseModel.isEmpty else { return nil }
    return modelOptions.first { $0.id == baseModel || $0.model == baseModel }?.label ?? baseModel
  }

  /// The default model's menu title: "Default (GPT-5.2 Codex)", or "Agent default".
  public var defaultModelTitle: String {
    resolvedDefaultModelName.map { "Default (\($0))" } ?? "Agent default"
  }

  /// The model the chip names: the choice, else what the default resolves to.
  public var modelTitle: String {
    selectedModel?.label ?? selectedModelId ?? resolvedDefaultModelName ?? "Agent default"
  }

  /// The model is the agent's default rather than a choice (the chip dims it).
  public var isModelInherited: Bool { selectedModelId == nil }

  /// The selected model, else the default one: the row whose efforts apply.
  public var effectiveModel: ModelOption? { selectedModel ?? defaultModel }

  /// Efforts the selected (or default) model supports.
  public var efforts: [String] { effectiveModel?.supportedReasoningEfforts ?? [] }

  /// The effective model's default effort, when reported.
  public var defaultEffort: String? { effectiveModel?.defaultReasoningEffort }

  /// The default effort's menu title: "Default (Medium)", or "Agent default".
  public var defaultEffortTitle: String {
    defaultEffort.map { "Default (\(Self.effortLabel($0)))" } ?? "Agent default"
  }

  /// The effort the chip names, or `nil` when the model has no effort choice.
  public var effortTitle: String? {
    if let selectedEffort { return Self.effortLabel(selectedEffort) }
    guard !efforts.isEmpty else { return nil }
    return defaultEffort.map(Self.effortLabel)
  }

  /// `Agent · Model · Effort`, for the chip's help and accessibility.
  public var title: String {
    [agentTitle, modelTitle, effortTitle].compactMap(\.self).joined(separator: " \u{00B7} ")
  }

  /// Whether `model` (`nil`: the default) can be chosen for the selected agent.
  /// - Parameter model: A model id.
  /// - Returns: Whether it is offered.
  public func canSelect(model: String?) -> Bool {
    guard let model else { return true }
    return visibleModels.contains { $0.id == model }
  }

  /// The effort to keep after choosing `model`: the current one when the new model supports it
  /// (or reports no efforts), else the default.
  /// - Parameter model: The new model id, `nil` for the default.
  /// - Returns: The effort to keep.
  public func effortKept(selecting model: String?) -> String? {
    guard let selectedEffort else { return nil }
    let row = model.flatMap { id in modelOptions.first { $0.id == id } } ?? defaultModel
    guard let supported = row?.supportedReasoningEfforts, !supported.isEmpty else {
      return selectedEffort
    }
    return supported.contains(selectedEffort) ? selectedEffort : nil
  }

  /// This configuration with choices the selected agent does not offer reset to the defaults.
  public var validated: Self {
    var copy = self
    if !canSelect(model: selectedModelId) { copy.selectedModelId = nil }
    if let effort = copy.selectedEffort, !copy.efforts.isEmpty, !copy.efforts.contains(effort) {
      copy.selectedEffort = nil
    }
    return copy
  }

  /// The web's effort labels: "Low", "Medium", "High", "xHigh", "Max".
  /// - Parameter effort: The wire value.
  /// - Returns: The label.
  public static func effortLabel(_ effort: String) -> String {
    switch effort.lowercased() {
    case "xhigh", "x-high", "extra_high": "xHigh"
    default: effort.prefix(1).uppercased() + effort.dropFirst()
    }
  }
}

/// What a send does now: the composer says it before the user presses Send.
nonisolated public enum ComposerSendIntent: Hashable, Sendable {
  /// Sends (nothing is running).
  case send
  /// Sends now into the running turn.
  case steer
  /// Waits in the queue and sends after the running turn.
  case queue

  /// What happens, for the label next to Send; `nil` when it simply sends.
  public var label: String? {
    switch self {
    case .send: nil
    case .steer: "Send now \u{00B7} steer"
    case .queue: "Queued \u{00B7} after this turn"
    }
  }

  /// What a send does in this state. Queued messages keep their order, so a send joins the
  /// queue while it has items. While a turn runs, a harness that takes mid-turn input steers
  /// (Omnigent's default); otherwise the message is queued.
  /// - Parameters:
  ///   - isRunning: A turn is running.
  ///   - canSteer: The harness takes mid-turn input.
  ///   - hasQueue: Messages are already queued.
  ///   - canQueue: The host keeps a queue.
  ///   - prefersSteer: Steer rather than queue while a turn runs.
  /// - Returns: The intent.
  public static func resolve(
    isRunning: Bool, canSteer: Bool, hasQueue: Bool, canQueue: Bool, prefersSteer: Bool = true
  ) -> Self {
    guard canQueue else { return isRunning ? (canSteer ? .steer : .queue) : .send }
    if hasQueue { return .queue }
    guard isRunning else { return .send }
    return canSteer && prefersSteer ? .steer : .queue
  }

  /// The other choice while a turn runs (the Send button's menu and Option-Return), if any.
  /// - Parameters:
  ///   - canSteer: The harness takes mid-turn input.
  ///   - canQueue: The host keeps a queue.
  /// - Returns: The alternative.
  public func alternative(canSteer: Bool, canQueue: Bool) -> Self? {
    switch self {
    case .send: nil
    case .steer: canQueue ? .queue : nil
    case .queue: canSteer ? .steer : nil
    }
  }
}
