public import Observation
public import OmnigentCoreFFI

/// Where a fork request stands.
public enum ForkPhase: Equatable, Sendable {
  /// No request yet, or the last one was dismissed.
  case idle
  /// The request is in flight.
  case forking
  /// The server refused it, or the choice was unusable; nothing was created.
  case failed(CoreError)
  /// The server may have created the fork, but confirmation was lost. Forking stays blocked
  /// until ``ForkStore/acknowledgeUncertain()``: it is never retried automatically.
  case uncertain(CoreError)
  /// Created. A failed start leaves the fork unbound and is reported here.
  case forked(sessionID: String, launchError: CoreError?)
}

/// The fork sheet: the creation catalog for its choices, and one fork at a time that is never
/// repeated.
@Observable
public final class ForkStore {
  /// Hosts and agents, for the sheet's agent list and the start host's state.
  public private(set) var catalog: CreationLoad<CreationCatalog> = .idle
  /// The request state.
  public private(set) var phase: ForkPhase = .idle
  /// Models the chosen host advertises for the chosen agent.
  public private(set) var models: CreationLoad<[ModelChoice]> = .idle

  /// What a fork onto a new sandbox can launch with.
  public let sandboxes: SandboxStore

  private let core: ClientCore
  private var modelsGeneration = 0

  init(core: ClientCore) {
    self.core = core
    sandboxes = SandboxStore(core: core)
  }

  /// Whether a fork can start now (none in flight, none unacknowledged as uncertain).
  public var canFork: Bool {
    switch phase {
    case .forking, .uncertain: false
    case .idle, .failed, .forked: true
    }
  }

  /// Why the request failed or may have landed, for the sheet.
  public var errorMessage: String? {
    switch phase {
    case .failed(let error), .uncertain(let error): error.message
    case .idle, .forking, .forked: nil
    }
  }

  /// Loads the hosts and agents. A failure is kept in ``catalog`` and the plan says why a start
  /// is unavailable.
  public func loadCatalog() async {
    catalog = .loading
    do {
      catalog = .loaded(try await core.creationCatalog())
    } catch {
      catalog = .failed(coreError(error))
    }
  }

  /// The agent or host changed: loads the agent's models on the host. A newer choice
  /// supersedes an older one's result; no host clears them.
  /// - Parameters:
  ///   - agentID: The agent.
  ///   - hostID: The host, or `nil` for a new sandbox.
  public func loadModels(agentID: String, hostID: String?) async {
    modelsGeneration += 1
    let generation = modelsGeneration
    guard let hostID, !agentID.isEmpty else {
      models = .idle
      return
    }
    models = .loading
    let result: CreationLoad<[ModelChoice]>
    do {
      result = .loaded(try await core.creationModels(agentId: agentID, hostId: hostID))
    } catch {
      result = .failed(coreError(error))
    }
    guard generation == modelsGeneration else { return }
    models = result
  }

  /// The directories in `path` on `hostID` (its home when `nil`), for the folder browser.
  /// - Returns: The listing, or why it could not be read.
  public func directory(hostID: String, path: String?) async -> Result<
    HostDirectoryListing, CoreError
  > {
    do {
      return .success(try await core.hostDirectory(hostId: hostID, path: path))
    } catch {
      return .failure(coreError(error))
    }
  }

  /// The sheet's choices for `source`, from the core.
  /// - Parameter source: The session being forked.
  /// - Returns: The agents, defaults and why a start is unavailable.
  public func plan(for source: SessionSummary) -> ForkPlan {
    forkPlan(source: source, catalog: catalog.value)
  }

  /// Forks, and starts the fork when `request.start` is set. Never retried: an unclear outcome
  /// becomes ``ForkPhase/uncertain(_:)``.
  /// - Parameter request: What to fork.
  /// - Returns: The new session's id once it exists (even when its start failed), else `nil`
  ///   with the failure in ``phase``.
  @discardableResult
  public func fork(_ request: ForkRequest) async -> String? {
    guard canFork else { return nil }
    phase = .forking
    do {
      let forked = try await core.forkSession(request: request)
      let launchError: CoreError? =
        switch forked.launch {
        case .notRequested, .launched: nil
        case .failed(let error): error
        }
      phase = .forked(sessionID: forked.receipt.sessionId, launchError: launchError)
      return forked.receipt.sessionId
    } catch {
      let error = coreError(error)
      phase = error.isDeliveryUncertain ? .uncertain(error) : .failed(error)
      return nil
    }
  }

  /// The user checked Sessions after an uncertain fork; another fork may start.
  public func acknowledgeUncertain() {
    if case .uncertain = phase { phase = .idle }
  }

  /// Returns to idle after a failure or a finished fork. An uncertain fork stays until it is
  /// acknowledged.
  public func reset() {
    switch phase {
    case .idle, .forking, .uncertain: return
    case .failed, .forked: phase = .idle
    }
  }
}

extension ConnectionStore {
  /// A fork store for one sheet.
  /// - Returns: The store, or `nil` when the core did not start.
  public func makeForkStore() -> ForkStore? {
    guard let core else { return nil }
    return ForkStore(core: core)
  }
}
