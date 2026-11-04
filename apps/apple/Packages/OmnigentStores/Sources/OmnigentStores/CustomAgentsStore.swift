public import Foundation
public import Observation
public import OmnigentCoreFFI

/// Custom agents on one server: creating one from the form or a `.tar.gz` bundle, and the
/// Settings list, configuration edits and removal. Writes are never retried; failures are kept
/// for the sheet.
@Observable
public final class CustomAgentsStore {
  /// The server's agents.
  public private(set) var serverAgents: CreationLoad<[ManagedAgent]> = .idle
  /// The caller's own agents.
  public private(set) var myAgents: CreationLoad<[ManagedAgent]> = .idle
  /// The configuration being edited.
  public private(set) var config: CreationLoad<AgentConfig> = .idle
  /// A write is in flight.
  public private(set) var isSaving = false
  /// The last write's failure.
  public private(set) var error: CoreError?
  /// Set when a removal was refused because sessions still use the agent: the server's
  /// explanation. Remove again with `force` to remove it anyway.
  public private(set) var inUseMessage: String?

  private let core: ClientCore

  init(core: ClientCore) {
    self.core = core
  }

  /// Reads both lists.
  public func load() async {
    async let server = Self.read { try await self.core.managedAgents(mine: false) }
    async let mine = Self.read { try await self.core.managedAgents(mine: true) }
    if serverAgents.value == nil { serverAgents = .loading }
    if myAgents.value == nil { myAgents = .loading }
    (serverAgents, myAgents) = await (server, mine)
  }

  /// Saves the form as the caller's agent (replacing one with the same name).
  /// - Parameter draft: The form.
  /// - Returns: The agent, or `nil` with the failure in ``error``.
  public func create(_ draft: AgentDraft) async -> ManagedAgent? {
    await write { try await $0.installAgent(draft: draft) }
  }

  /// Installs a `.tar.gz` bundle the user picked.
  /// - Parameters:
  ///   - data: The bundle.
  ///   - filename: Its file name.
  /// - Returns: The agent, or `nil` with the failure in ``error``.
  public func importBundle(_ data: Data, filename: String) async -> ManagedAgent? {
    await write { try await $0.installAgentBundle(bundle: data, filename: filename) }
  }

  /// Reads `agentID`'s configuration for editing.
  /// - Parameter agentID: The caller's agent.
  public func loadConfig(_ agentID: String) async {
    config = .loading
    error = nil
    do {
      config = .loaded(try await core.agentConfig(agentId: agentID))
    } catch {
      config = .failed(coreError(error))
    }
  }

  /// Saves `edit` over the loaded configuration.
  /// - Parameter edit: The fields.
  /// - Returns: Whether it saved.
  @discardableResult
  public func save(_ edit: AgentConfigEdit) async -> Bool {
    guard let current = config.value else { return false }
    guard let saved = await write({ try await $0.updateAgentConfig(current: current, edit: edit) })
    else { return false }
    config = .loaded(saved)
    return true
  }

  /// Removes `agentID`. Without `force`, an agent still in use is kept and ``inUseMessage``
  /// says why.
  /// - Parameters:
  ///   - agentID: The caller's agent.
  ///   - force: Remove even though sessions use it.
  /// - Returns: Whether it was removed.
  @discardableResult
  public func remove(_ agentID: String, force: Bool = false) async -> Bool {
    inUseMessage = nil
    guard let removal = await write({ try await $0.removeAgent(agentId: agentID, force: force) })
    else { return false }
    switch removal {
    case .removed:
      if case .loaded(let agents) = myAgents {
        myAgents = .loaded(agents.filter { $0.id != agentID })
      }
      return true
    case .inUse(let message):
      inUseMessage = message
      return false
    }
  }

  /// Records a bundle the app could not read before installing it.
  /// - Parameter message: What went wrong.
  public func recordImportFailure(_ message: String) {
    error = .InvalidState(message: message)
  }

  /// Clears the last failure and in-use notice.
  public func dismissMessages() {
    error = nil
    inUseMessage = nil
  }

  private func write<Value>(_ body: (ClientCore) async throws -> Value) async -> Value? {
    guard !isSaving else { return nil }
    isSaving = true
    error = nil
    defer { isSaving = false }
    do {
      return try await body(core)
    } catch {
      self.error = coreError(error)
      return nil
    }
  }

  private static func read(
    _ body: () async throws -> [ManagedAgent]
  ) async -> CreationLoad<[ManagedAgent]> {
    do {
      return .loaded(try await body())
    } catch {
      return .failed(coreError(error))
    }
  }
}

extension ConnectionStore {
  /// Custom agents for this server: a new store each time a sheet or Settings opens.
  /// - Returns: The store, or `nil` without a core.
  public func customAgents() -> CustomAgentsStore? {
    core.map { CustomAgentsStore(core: $0) }
  }
}
