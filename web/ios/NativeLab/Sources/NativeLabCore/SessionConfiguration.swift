import Foundation

public struct ModelChoice: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var model: String?
  public var displayName: String?
  public var description: String?
  public var hidden: Bool?
  public var isDefault: Bool?
  public var defaultReasoningEffort: String?
  public var supportedReasoningEfforts: [ReasoningChoice]?

  public var title: String { displayName ?? model ?? id }
  public var value: String { model ?? id }
  public func matches(_ value: String?) -> Bool {
    guard let value else { return false }
    return value == id || value == model
  }
}

public struct ReasoningChoice: Codable, Equatable, Sendable {
  public var reasoningEffort: String
  public var description: String?
}

public struct SessionConfiguration: Codable, Equatable, Sendable {
  public var agentID: String?
  public var harness: String?
  public var wrapper: String?
  public var modelOverride: String?
  public var baseModel: String?
  public var effort: String?
  public var modelReported: Bool?
  public var effortReported: Bool?
  public var models: [ModelChoice] = []
  public var hostID: String?
  public var hostOnline: Bool?
  public var runnerOnline: Bool?
  public var runnerBound: Bool?
  public var hostResumable: Bool?
  public var parentID: String?
  public var routingMode: String?

  public init() {}

  /// A stopped runner can be relaunched by its connected host or a wakeable managed host.
  public var executionUnavailableReason: String? {
    // Legacy liveness treats unbound sessions as online for in-process executors.
    let unboundNative =
      Self.canonicalHarness(harness).hasSuffix("-native")
      && runnerBound == false && (hostID ?? "").isEmpty
    if runnerOnline == true && !unboundNative { return nil }
    if let hostID, !hostID.isEmpty {
      if hostOnline == true || hostResumable == true { return nil }
      guard hostOnline == false else { return nil }
      return
        "This session's host is offline. Reconnect that host, or create a new session on a connected host from Sessions. Your draft stays here."
    }
    // Missing liveness is unknown, not proof that a session cannot execute.
    guard unboundNative || runnerOnline == false else { return nil }
    return
      "This session has no execution connection. To chat, go to Sessions, tap New session, and choose a connected host. Your draft stays here."
  }

  public var harnessLabel: String { Self.harnessLabel(harness) }
  public var effectiveModel: String? { modelOverride ?? baseModel }
  public var modelLabel: String {
    if routingMode == "on" { return "Smart routing" }
    guard let value = effectiveModel else {
      return modelReported == true ? "Harness default" : "Model not reported"
    }
    return models.first(where: { $0.matches(value) })?.title ?? value
  }
  public var identityLabel: String { "\(harnessLabel) · \(modelLabel)" }
  public var effortLabel: String {
    effort?.capitalized ?? (effortReported == true ? "Harness default" : "Not reported")
  }

  public var supportsModels: Bool {
    [
      "codex-native", "claude-native", "cursor-native", "kiro-native", "pi-native",
      "opencode-native",
    ]
    .contains(Self.canonicalHarness(harness))
  }
  public var supportsEffort: Bool {
    wrapper == "codex-native-ui" || wrapper == "claude-code-native-ui"
  }

  public func efforts(for model: String?) -> [String] {
    guard supportsEffort else { return [] }
    // Clearing the override restores the runner's default, not the spec's base model.
    let option =
      model == nil
      ? models.first(where: { $0.isDefault == true })
      : models.first(where: { $0.matches(model) })
    if let values = option?.supportedReasoningEfforts {
      return values.map(\.reasoningEffort).reduce(into: []) {
        if !$0.contains($1) { $0.append($1) }
      }
    }
    // Claude's supported effort vocabulary is owned by reasoning_effort.py.
    return wrapper == "claude-code-native-ui" ? ["low", "medium", "high", "xhigh", "max"] : []
  }

  public func sameSelection(as other: Self) -> Bool {
    agentID == other.agentID && harness == other.harness && wrapper == other.wrapper
      && modelOverride == other.modelOverride && baseModel == other.baseModel
      && effort == other.effort && routingMode == other.routingMode && hostID == other.hostID
  }

  public static func canonicalHarness(_ value: String?) -> String {
    switch value {
    case "native-codex": return "codex-native"
    case "native-claude": return "claude-native"
    case "native-hermes": return "hermes-native"
    case "native-pi": return "pi-native"
    case "native-qwen": return "qwen-native"
    case "native-cursor": return "cursor-native"
    case "native-kiro": return "kiro-native"
    case "native-opencode": return "opencode-native"
    case "native-antigravity": return "antigravity-native"
    case "claude_sdk": return "claude-sdk"
    case "agents_sdk", "openai-agents-sdk": return "openai-agents"
    default: return value ?? ""
    }
  }

  public static func harnessLabel(_ value: String?) -> String {
    switch canonicalHarness(value) {
    case "codex-native": return "Codex"
    case "claude-native": return "Claude Code"
    case "claude-sdk": return "Claude SDK"
    case "openai-agents": return "OpenAI Agents"
    case "pi-native": return "Pi"
    case "hermes-native": return "Hermes"
    case "qwen-native": return "Qwen Code"
    case "cursor-native": return "Cursor"
    case "kiro-native": return "Kiro"
    case "opencode-native": return "OpenCode"
    case "": return "Harness not reported"
    default: return value ?? "Harness not reported"
    }
  }

  public static func family(_ harness: String?) -> String? {
    switch canonicalHarness(harness) {
    case "codex", "codex-native", "openai-agents", "antigravity", "qwen", "qwen-native":
      return "openai"
    case "claude-native", "claude-sdk": return "anthropic"
    case "antigravity-native": return "gemini"
    default: return nil
    }
  }
}

public struct ConfigurationEdit: Equatable, Sendable {
  public let baseline: SessionConfiguration
  public var model: String?
  public var effort: String?

  public init(_ configuration: SessionConfiguration) {
    baseline = configuration
    model = configuration.modelOverride
    effort = configuration.effort
  }
  public var hasChanges: Bool { model != baseline.modelOverride || effort != baseline.effort }
  public mutating func selectModel(_ model: String?) {
    self.model = model
    if let effort, !baseline.efforts(for: model).contains(effort) { self.effort = nil }
  }

  public func validate(against current: SessionConfiguration) throws {
    guard baseline.sameSelection(as: current) else { throw ConfigurationError.changedElsewhere }
    if model != baseline.modelOverride {
      guard current.supportsModels, current.routingMode != "on", !current.models.isEmpty,
        model == nil || current.models.contains(where: { $0.matches(model) && $0.hidden != true })
      else {
        throw ConfigurationError.unavailable(
          "This model is not currently advertised by the runner.")
      }
    }
    if effort != baseline.effort || (model != baseline.modelOverride && effort != nil) {
      guard current.supportsEffort,
        effort == nil || current.efforts(for: model).contains(effort!)
      else {
        throw ConfigurationError.unavailable(
          "This reasoning level is not supported by the selected model.")
      }
    }
  }
}

public enum ConfigurationError: Error, LocalizedError, Equatable {
  case changedElsewhere
  case unavailable(String)

  public var errorDescription: String? {
    switch self {
    case .changedElsewhere:
      return "Settings changed elsewhere. Review the current settings before applying your choices."
    case .unavailable(let message): return message
    }
  }
}

public struct HarnessChoice: Decodable, Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let harness: String?
  public let builtin: Bool?
  public var title: String { SessionConfiguration.harnessLabel(harness) }
  public var preservesHistory: Bool {
    [
      "codex-native", "claude-native", "pi-native", "hermes-native", "qwen-native",
      "claude-sdk", "openai-agents", "codex", "antigravity",
    ]
    .contains(SessionConfiguration.canonicalHarness(harness))
  }
}

public struct ConfigurationHost: Decodable, Equatable, Sendable {
  public let hostID: String
  public let name: String
  public let status: String
  let configuredHarnesses: [String: JSONValue]?
  enum CodingKeys: String, CodingKey {
    case name, status
    case hostID = "host_id"
    case configuredHarnesses = "configured_harnesses"
  }
}

public struct ConfigurationCatalog: Equatable, Sendable {
  public let agents: [HarnessChoice]
  public let host: ConfigurationHost?
  public var modelOptions: [ModelChoice] = []
  public var modelOptionsError: String?
  var modelOptionsIdentity: SessionConfiguration?

  public func configurationByAddingModelOptions(to current: SessionConfiguration)
    -> SessionConfiguration
  {
    guard current.models.isEmpty, let identity = modelOptionsIdentity,
      identity.sameSelection(as: current)
    else { return current }
    var enriched = current
    enriched.models = modelOptions
    return enriched
  }

  public func unavailableReason(for target: HarnessChoice, current: SessionConfiguration) -> String?
  {
    if target.id == current.agentID
      || (target.harness != nil
        && SessionConfiguration.canonicalHarness(target.harness)
          == SessionConfiguration.canonicalHarness(current.harness))
    {
      return "Current harness"
    }
    if current.parentID != nil { return "Child sessions cannot switch harness." }
    if target.builtin != true { return "Only built-in agents can be selected here." }
    if !target.preservesHistory {
      return "This target cannot preserve history during an in-place switch."
    }
    guard let host, host.hostID == current.hostID, host.status == "online" else {
      return "The session's host must be online."
    }
    guard let harness = target.harness,
      let readiness = host.configuredHarnesses?[SessionConfiguration.canonicalHarness(harness)]
        ?? host.configuredHarnesses?[harness]
    else {
      return "Host readiness has not been reported."
    }
    if readiness == .bool(true) { return nil }
    if readiness == .string("needs-auth") { return "Sign in to this harness on the host first." }
    return "This harness is not configured on the host."
  }
}
