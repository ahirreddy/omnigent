import Foundation

public enum CreationReadiness: Decodable, Equatable, Sendable {
  case ready
  case notReady
  case needsAuthentication
  case unknown

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    if let ready = try? value.decode(Bool.self) {
      self = ready ? .ready : .notReady
    } else if (try? value.decode(String.self)) == "needs-auth" {
      self = .needsAuthentication
    } else {
      self = .unknown
    }
  }
}

public struct CreationHost: Decodable, Equatable, Sendable, Identifiable {
  public let hostID: String
  public let name: String
  public let status: String
  public let sandboxProvider: String?
  public let configuredHarnesses: [String: CreationReadiness]?
  public var id: String { hostID }
  public var isAvailable: Bool { status == "online" && sandboxProvider == nil }

  public init(
    hostID: String, name: String, status: String, sandboxProvider: String? = nil,
    configuredHarnesses: [String: CreationReadiness]? = nil
  ) {
    self.hostID = hostID
    self.name = name
    self.status = status
    self.sandboxProvider = sandboxProvider
    self.configuredHarnesses = configuredHarnesses
  }

  enum CodingKeys: String, CodingKey {
    case name, status
    case hostID = "host_id"
    case sandboxProvider = "sandbox_provider"
    case configuredHarnesses = "configured_harnesses"
  }
}

public struct CreationAgent: Decodable, Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let harness: String?
  public let description: String?
  public var harnessID: String { SessionConfiguration.canonicalHarness(harness) }
  public var harnessLabel: String { SessionConfiguration.harnessLabel(harness) }

  public init(id: String, name: String, harness: String?, description: String? = nil) {
    self.id = id
    self.name = name
    self.harness = harness
    self.description = description
  }

  // These wrappers transport chat and approvals through the session API.
  public var wrapper: String? {
    switch harnessID {
    case "claude-native": return "claude-code-native-ui"
    case "codex-native", "cursor-native", "kiro-native", "pi-native", "opencode-native":
      return "\(harnessID)-ui"
    default: return nil
    }
  }

  public var supportsCreation: Bool {
    wrapper != nil
      || ["codex", "claude-sdk", "openai-agents", "pi", "antigravity"].contains(harnessID)
  }

  public var supportsModelPreview: Bool { wrapper != nil }
}

public struct CreationWorkspace: Equatable, Sendable, Identifiable {
  public let path: String
  public let name: String
  public var id: String { path }

  public init(path: String, name: String) {
    self.path = path
    self.name = name
  }
}

public struct SessionCreationSelection: Equatable, Sendable {
  public var hostID: String
  public var agentID: String
  public var workspace: String
  public var model: String?

  public init(
    hostID: String = "", agentID: String = "", workspace: String = "", model: String? = nil
  ) {
    self.hostID = hostID
    self.agentID = agentID
    self.workspace = workspace
    self.model = model
  }
}

public struct SessionCreationCatalog: Equatable, Sendable {
  public let hosts: [CreationHost]
  public let agents: [CreationAgent]

  public init(hosts: [CreationHost], agents: [CreationAgent]) {
    self.hosts = hosts
    self.agents = agents
  }

  public func unavailableReason(agentID: String, hostID: String) -> String? {
    guard let host = hosts.first(where: { $0.id == hostID }) else {
      return "Choose an existing host."
    }
    guard host.sandboxProvider == nil else {
      return "Managed sandbox creation is not available here."
    }
    guard host.status == "online" else { return "Connect this host before starting a session." }
    guard let agent = agents.first(where: { $0.id == agentID }) else {
      return "Choose a registered agent."
    }
    guard agent.supportsCreation else {
      return "This agent's harness is not supported for creation in this app."
    }
    let readiness =
      host.configuredHarnesses?[agent.harnessID]
      ?? agent.harness.flatMap { host.configuredHarnesses?[$0] }
    if readiness == .ready { return nil }
    if readiness == .needsAuthentication { return "Sign in to this harness on the host first." }
    if readiness == nil { return "The host has not reported readiness for this harness." }
    return "Configure this harness on the host before starting a session."
  }

  public func validate(_ selection: SessionCreationSelection, models: [ModelChoice] = []) throws {
    if let reason = unavailableReason(agentID: selection.agentID, hostID: selection.hostID) {
      throw SessionCreationError.unavailable(reason)
    }
    let path = selection.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
    guard path.hasPrefix("/"), !path.contains("\0") else {
      throw SessionCreationError.unavailable("Enter an absolute workspace path beginning with /.")
    }
    if let model = selection.model {
      guard agents.first(where: { $0.id == selection.agentID })?.supportsModelPreview == true,
        models.contains(where: { $0.value == model && $0.hidden != true })
      else {
        throw SessionCreationError.unavailable(
          "This model is not currently advertised by the selected host.")
      }
    }
  }
}

public struct SessionCreationReceipt: Equatable, Sendable {
  public let sessionID: String
  public let summary: SessionSummary?
}

public enum SessionCreationError: Error, LocalizedError, Equatable, Sendable {
  case unavailable(String)
  case rejected(status: Int, message: String)
  case uncertain

  public var errorDescription: String? {
    switch self {
    case .unavailable(let message), .rejected(_, let message): return message
    case .uncertain:
      return
        "The server may have created this session, but confirmation was lost. Close this form and refresh Sessions before starting another. Your first message has not been sent."
    }
  }
}
