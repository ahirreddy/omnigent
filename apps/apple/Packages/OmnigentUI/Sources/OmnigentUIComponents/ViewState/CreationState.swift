import Foundation

// `configuredHarnesses` mirrors the core's `Option<BTreeMap>`: `nil` means the host did not
// report readiness, which the core treats differently from an empty map.
// swiftlint:disable discouraged_optional_collection

// Mirrors of the core's creation records (`omnigent_core::creation`). Availability and
// validation stay in the core: the sheet asks `NewSessionActions.unavailableReason`.

/// What a host reports for one harness in `configured_harnesses`.
nonisolated public enum HarnessReadiness: String, Hashable, Sendable {
  /// `true`.
  case ready
  /// `false`.
  case notReady
  /// `"needs-auth"`: the harness needs a sign-in on the host.
  case needsAuthentication
  /// Any other value. Never treated as ready.
  case unknown
}

/// One `GET /v1/hosts` row.
nonisolated public struct CreationHost: Hashable, Sendable, Identifiable {
  /// Host id.
  public var hostId: String
  /// Display name.
  public var name: String
  /// `online`, `offline`, ...
  public var status: String
  /// Set for managed sandbox hosts.
  public var sandboxProvider: String?
  /// Per-harness readiness, when reported.
  public var configuredHarnesses: [String: HarnessReadiness]?

  /// The host id.
  public var id: String { hostId }

  /// Creates a host row.
  /// - Parameters:
  ///   - hostId: Host id.
  ///   - name: Display name.
  ///   - status: Status.
  ///   - sandboxProvider: Managed sandbox provider.
  ///   - configuredHarnesses: Harness readiness.
  public init(
    hostId: String, name: String, status: String, sandboxProvider: String? = nil,
    configuredHarnesses: [String: HarnessReadiness]? = nil
  ) {
    self.hostId = hostId
    self.name = name
    self.status = status
    self.sandboxProvider = sandboxProvider
    self.configuredHarnesses = configuredHarnesses
  }

  /// Online and not a managed sandbox (the core's `CreationHost::is_available`).
  public var isAvailable: Bool { status == "online" && sandboxProvider == nil }
}

/// One `GET /v1/agents` row.
nonisolated public struct CreationAgent: Hashable, Sendable, Identifiable {
  /// Durable agent id.
  public var id: String
  /// Display name.
  public var name: String
  /// Harness as sent (aliases included).
  public var harness: String?
  /// Description.
  public var description: String?

  /// Creates an agent row.
  /// - Parameters:
  ///   - id: Agent id.
  ///   - name: Display name.
  ///   - harness: Harness.
  ///   - description: Description.
  public init(id: String, name: String, harness: String? = nil, description: String? = nil) {
    self.id = id
    self.name = name
    self.harness = harness
    self.description = description
  }
}

/// A directory offered as a session workspace.
nonisolated public struct CreationWorkspace: Hashable, Sendable, Identifiable {
  /// Absolute path.
  public var path: String
  /// Display name.
  public var name: String

  /// The path.
  public var id: String { path }

  /// Creates a workspace.
  /// - Parameters:
  ///   - path: Absolute path.
  ///   - name: Display name.
  public init(path: String, name: String) {
    self.path = path
    self.name = name
  }
}

/// What the user chose in the new-session form.
nonisolated public struct CreationSelection: Hashable, Sendable {
  /// Host id.
  public var hostId: String
  /// Agent id.
  public var agentId: String
  /// Workspace path, as typed.
  public var workspace: String
  /// The model's wire value, or `nil` for the harness default.
  public var model: String?

  /// Creates a selection.
  /// - Parameters:
  ///   - hostId: Host id.
  ///   - agentId: Agent id.
  ///   - workspace: Workspace path.
  ///   - model: Model wire value.
  public init(
    hostId: String = "", agentId: String = "", workspace: String = "", model: String? = nil
  ) {
    self.hostId = hostId
    self.agentId = agentId
    self.workspace = workspace
    self.model = model
  }
}

/// The hosts and agents a session can be created with.
nonisolated public struct CreationCatalog: Hashable, Sendable {
  /// Hosts, de-duplicated by id.
  public var hosts: [CreationHost]
  /// Agents, de-duplicated by id.
  public var agents: [CreationAgent]

  /// Creates a catalog.
  /// - Parameters:
  ///   - hosts: Hosts.
  ///   - agents: Agents.
  public init(hosts: [CreationHost] = [], agents: [CreationAgent] = []) {
    self.hosts = hosts
    self.agents = agents
  }
}

/// A load that may be in flight or failed.
nonisolated public enum LoadPhase<Value: Hashable & Sendable>: Hashable, Sendable {
  /// Not requested yet.
  case idle
  /// Loading.
  case loading
  /// Loaded.
  case loaded(Value)
  /// Failed; the message says why.
  case failed(message: String)

  /// The loaded value.
  public var value: Value? {
    if case .loaded(let value) = self { return value }
    return nil
  }

  /// Loading is in flight.
  public var isLoading: Bool { self == .loading }

  /// The failure message.
  public var errorMessage: String? {
    if case .failed(let message) = self { return message }
    return nil
  }
}

/// Where a creation request stands.
nonisolated public enum CreationPhase: Hashable, Sendable {
  /// Editing.
  case editing
  /// The request is in flight.
  case creating
  /// The server rejected it and created nothing.
  case failed(message: String)
  /// The server may have created it, but confirmation was lost. Never retried automatically.
  case uncertain(message: String)
}

/// What the new-session sheet renders.
nonisolated public struct NewSessionViewState: Hashable, Sendable {
  /// Hosts and agents.
  public var catalog: LoadPhase<CreationCatalog>
  /// Folders offered on the selected host.
  public var workspaces: LoadPhase<[CreationWorkspace]>
  /// Models the selected host advertises for the selected agent.
  public var models: LoadPhase<[ModelOption]>
  /// The request state.
  public var phase: CreationPhase

  /// Creates sheet state.
  /// - Parameters:
  ///   - catalog: Hosts and agents.
  ///   - workspaces: Offered folders.
  ///   - models: Advertised models.
  ///   - phase: Request state.
  public init(
    catalog: LoadPhase<CreationCatalog> = .idle, workspaces: LoadPhase<[CreationWorkspace]> = .idle,
    models: LoadPhase<[ModelOption]> = .idle, phase: CreationPhase = .editing
  ) {
    self.catalog = catalog
    self.workspaces = workspaces
    self.models = models
    self.phase = phase
  }
}

/// New-session sheet actions.
public struct NewSessionActions {
  /// Why `selection` cannot be created (the core's `CreationCatalog::validate`), or `nil`.
  public var unavailableReason: @MainActor (CreationSelection) -> String?
  /// The host or agent changed: load folders and models for it.
  public var selectionChanged: (@MainActor (CreationSelection) -> Void)?
  /// Create the session. `title` and `firstMessage` may be empty.
  public var create: @MainActor (CreationSelection, _ title: String, _ firstMessage: String) -> Void
  /// Reload the catalog after a failure.
  public var reload: (@MainActor () -> Void)?
  /// The user checked Sessions after an uncertain creation; allow another.
  public var acknowledgeUncertain: (@MainActor () -> Void)?
  /// Close the sheet.
  public var cancel: @MainActor () -> Void

  /// Creates actions.
  /// - Parameters:
  ///   - unavailableReason: Core validation.
  ///   - selectionChanged: Selection changed.
  ///   - create: Create.
  ///   - reload: Reload the catalog.
  ///   - acknowledgeUncertain: Allow another creation.
  ///   - cancel: Close.
  public init(
    unavailableReason: @escaping @MainActor (CreationSelection) -> String?,
    selectionChanged: (@MainActor (CreationSelection) -> Void)? = nil,
    create:
      @escaping @MainActor (CreationSelection, _ title: String, _ firstMessage: String) -> Void,
    reload: (@MainActor () -> Void)? = nil, acknowledgeUncertain: (@MainActor () -> Void)? = nil,
    cancel: @escaping @MainActor () -> Void
  ) {
    self.unavailableReason = unavailableReason
    self.selectionChanged = selectionChanged
    self.create = create
    self.reload = reload
    self.acknowledgeUncertain = acknowledgeUncertain
    self.cancel = cancel
  }
}

// swiftlint:enable discouraged_optional_collection
