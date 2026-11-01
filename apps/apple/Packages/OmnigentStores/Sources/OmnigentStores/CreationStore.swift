import Foundation
public import Observation
public import OmnigentCoreFFI

/// One load the new-session form waits for.
public enum CreationLoad<Value: Sendable & Equatable>: Equatable, Sendable {
  /// Not requested.
  case idle
  /// In flight.
  case loading
  /// Loaded.
  case loaded(Value)
  /// Failed.
  case failed(CoreError)

  /// The loaded value.
  public var value: Value? {
    if case .loaded(let value) = self { return value }
    return nil
  }
}

/// Where a creation request stands.
public enum CreationPhase: Equatable, Sendable {
  /// Editing the form.
  case editing
  /// The request is in flight.
  case creating
  /// The server rejected it, or the selection is unavailable; nothing was created.
  case failed(CoreError)
  /// The server may have created the session, but confirmation was lost. Creation stays
  /// blocked until ``CreationStore/acknowledgeUncertain()``: it is never retried automatically.
  case uncertain(CoreError)
  /// Created. When the first message failed, retry it with ``CreationStore/retryFirstMessage()``,
  /// which sends to the created session and never creates another.
  case created(sessionID: String, firstMessageError: CoreError?)
}

/// The new-session form: the catalog, the selected host's folders and models, validation by
/// the core, and one creation at a time that is never repeated.
@Observable
public final class CreationStore {
  /// Hosts and agents.
  public private(set) var catalog: CreationLoad<CreationCatalog> = .idle
  /// Folders offered on the selected host.
  public private(set) var workspaces: CreationLoad<[CreationWorkspace]> = .idle
  /// Models the selected host advertises for the selected agent.
  public private(set) var models: CreationLoad<[ModelChoice]> = .idle
  /// The request state.
  public private(set) var phase: CreationPhase = .editing

  private let core: ClientCore
  private var pendingFirstMessage: String?
  private var selectionGeneration = 0

  init(core: ClientCore) {
    self.core = core
  }

  /// Whether a creation can start now (none in flight, none unacknowledged as uncertain).
  public var canCreate: Bool {
    switch phase {
    case .creating, .uncertain: false
    case .editing, .failed, .created: true
    }
  }

  /// Loads the hosts and agents.
  public func loadCatalog() async {
    catalog = .loading
    do {
      catalog = .loaded(try await core.creationCatalog())
    } catch {
      catalog = .failed(coreError(error))
    }
  }

  /// The host or agent changed: loads the host's folders and the agent's models on it. A newer
  /// selection supersedes an older one's results.
  /// - Parameter selection: The current selection.
  public func selectionChanged(_ selection: CreationSelection) async {
    selectionGeneration += 1
    let generation = selectionGeneration
    workspaces = .loading
    models = .loading
    let folders: CreationLoad<[CreationWorkspace]>
    do {
      folders = .loaded(try await core.creationWorkspaces(hostId: selection.hostId))
    } catch {
      folders = .failed(coreError(error))
    }
    guard generation == selectionGeneration else { return }
    workspaces = folders
    let advertised: CreationLoad<[ModelChoice]>
    do {
      advertised = .loaded(
        try await core.creationModels(agentId: selection.agentId, hostId: selection.hostId))
    } catch {
      advertised = .failed(coreError(error))
    }
    guard generation == selectionGeneration else { return }
    models = advertised
  }

  /// Why `selection` cannot be created now (the core's validation against the loaded catalog
  /// and models), or `nil` when it can.
  /// - Parameter selection: The selection.
  /// - Returns: The reason to show.
  public func unavailableReason(_ selection: CreationSelection) -> String? {
    guard let catalog = catalog.value else { return "The host and agent list has not loaded." }
    return creationValidationError(
      catalog: catalog, selection: selection, models: models.value ?? [])
  }

  /// Creates the session, then sends `firstMessage` to it when it is not blank. Creation is
  /// never retried: an unclear outcome becomes ``CreationPhase/uncertain(_:)``.
  /// - Parameters:
  ///   - selection: Host, agent, workspace and model.
  ///   - title: The session name; may be empty.
  ///   - firstMessage: The first message; may be empty.
  public func create(_ selection: CreationSelection, title: String, firstMessage: String) async {
    guard canCreate else { return }
    phase = .creating
    let text = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      if text.isEmpty {
        let receipt = try await core.createSession(selection: selection, title: title)
        pendingFirstMessage = nil
        phase = .created(sessionID: receipt.sessionId, firstMessageError: nil)
      } else {
        let created = try await core.createSessionAndSend(
          selection: selection, title: title, text: firstMessage)
        switch created.firstMessage {
        case .sent:
          pendingFirstMessage = nil
          phase = .created(sessionID: created.receipt.sessionId, firstMessageError: nil)
        case .failed(let error):
          pendingFirstMessage = firstMessage
          phase = .created(sessionID: created.receipt.sessionId, firstMessageError: error)
        }
      }
    } catch {
      let error = coreError(error)
      phase = error.isDeliveryUncertain ? .uncertain(error) : .failed(error)
    }
  }

  /// Sends the first message again to the session that was created. Never creates another.
  public func retryFirstMessage() async {
    guard case .created(let sessionID, .some) = phase, let text = pendingFirstMessage else {
      return
    }
    do {
      _ = try await core.sendMessage(sessionId: sessionID, text: text)
      pendingFirstMessage = nil
      phase = .created(sessionID: sessionID, firstMessageError: nil)
    } catch {
      phase = .created(sessionID: sessionID, firstMessageError: coreError(error))
    }
  }

  /// The user checked Sessions after an uncertain creation; another creation may start.
  public func acknowledgeUncertain() {
    if case .uncertain = phase { phase = .editing }
  }

  /// Returns the form to editing after a failure or a finished creation.
  public func reset() {
    guard phase != .creating else { return }
    if case .uncertain = phase { return }
    pendingFirstMessage = nil
    phase = .editing
  }
}
