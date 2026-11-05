public import Foundation
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

/// A file staged on the new-session form, uploaded to the session once it exists.
public struct PendingAttachment: Identifiable, Equatable, Sendable {
  /// Stable within the form.
  public let id: UUID
  /// File name.
  public let filename: String
  /// Declared media type.
  public let mediaType: String?
  /// The bytes.
  public let data: Data

  /// Creates a staged file.
  public init(filename: String, mediaType: String?, data: Data) {
    id = UUID()
    self.filename = filename
    self.mediaType = mediaType
    self.data = data
  }
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
  /// Git worktrees of the selected folder's repository; empty when it is not one.
  public private(set) var worktrees: CreationLoad<[HostWorktree]> = .idle
  /// The request state.
  public private(set) var phase: CreationPhase = .editing
  /// Files to send with the first message.
  public private(set) var attachments: [PendingAttachment] = []
  /// The project the sidebar's "New session in project" chose: the new session is filed there
  /// and the form takes its defaults. The form clears it once read.
  public var pendingProject: ProjectSummary?

  private let core: ClientCore
  private var pendingFirstMessage: String?
  private var selectionGeneration = 0
  private var worktreeGeneration = 0

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

  /// The folder changed: loads its repository's worktrees on `hostID`. A newer folder supersedes
  /// an older one's result; an empty folder clears them.
  /// - Parameters:
  ///   - hostID: The host.
  ///   - path: The folder.
  public func folderChanged(hostID: String, path: String) async {
    worktreeGeneration += 1
    let generation = worktreeGeneration
    let trimmed = path.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("/"), !hostID.isEmpty else {
      worktrees = .idle
      return
    }
    worktrees = .loading
    let result: CreationLoad<[HostWorktree]>
    do {
      result = .loaded(try await core.hostWorktrees(hostId: hostID, path: trimmed))
    } catch {
      result = .failed(coreError(error))
    }
    guard generation == worktreeGeneration else { return }
    worktrees = result
  }

  /// `project`'s stored new-session defaults (Project settings), to fill in the form.
  /// - Parameter project: The project.
  /// - Returns: The defaults, or why they could not be read.
  public func projectSettings(_ project: ProjectSummary) async -> Result<
    ProjectSettings, CoreError
  > {
    do {
      return .success(try await core.projectSettings(project: project))
    } catch {
      return .failure(coreError(error))
    }
  }

  /// The directories in `path` on `hostID` (its home when `nil`), for the folder browser.
  /// - Parameters:
  ///   - hostID: The host.
  ///   - path: An absolute folder, or `nil` for the home folder.
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

  /// Why `selection` cannot be created now (the core's validation against the loaded catalog
  /// and models), or `nil` when it can.
  /// - Parameter selection: The selection.
  /// - Returns: The reason to show.
  public func unavailableReason(_ selection: CreationSelection) -> String? {
    guard let catalog = catalog.value else { return "The host and agent list has not loaded." }
    return creationValidationError(
      catalog: catalog, selection: selection, models: models.value ?? [])
  }

  /// Stages a file for the first message.
  public func stageAttachment(_ attachment: PendingAttachment) {
    attachments.append(attachment)
  }

  /// Removes a staged file.
  public func removeAttachment(_ id: UUID) {
    attachments.removeAll { $0.id == id }
  }

  /// Creates the session, then sends `firstMessage` to it when it is not blank. Creation is
  /// never retried: an unclear outcome becomes ``CreationPhase/uncertain(_:)``. Staged files
  /// are uploaded to the new session and sent with the first message.
  /// - Parameters:
  ///   - selection: Host, agent, workspace and model.
  ///   - title: The session name; may be empty.
  ///   - firstMessage: The first message; may be empty.
  public func create(_ selection: CreationSelection, title: String, firstMessage: String) async {
    guard canCreate else { return }
    phase = .creating
    let text = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      if !attachments.isEmpty {
        let receipt = try await core.createSession(selection: selection, title: title)
        pendingFirstMessage = firstMessage
        phase = .created(sessionID: receipt.sessionId, firstMessageError: nil)
        await sendWithAttachments(sessionID: receipt.sessionId, text: firstMessage)
      } else if text.isEmpty {
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

  /// Creates a session for `agentID` on a new sandbox the server provisions, cloning
  /// `workspaces` (`<url>[#<branch>]` repositories; empty for an empty sandbox). Like
  /// ``create(_:title:firstMessage:)`` it is never retried; the sandbox registers after the
  /// session exists.
  /// - Parameters:
  ///   - agentID: The agent.
  ///   - title: The session name; may be empty.
  ///   - workspaces: Repositories to clone.
  ///   - firstMessage: Sent once the session exists; may be empty.
  public func createInSandbox(
    agentID: String, title: String, workspaces: [String], firstMessage: String = ""
  ) async {
    guard canCreate else { return }
    phase = .creating
    do {
      let receipt = try await core.createSandboxSession(
        agentId: agentID, title: title, workspaces: workspaces)
      let text = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else {
        pendingFirstMessage = nil
        phase = .created(sessionID: receipt.sessionId, firstMessageError: nil)
        return
      }
      pendingFirstMessage = firstMessage
      phase = .created(sessionID: receipt.sessionId, firstMessageError: nil)
      do {
        _ = try await core.sendMessage(sessionId: receipt.sessionId, text: firstMessage)
        pendingFirstMessage = nil
      } catch {
        phase = .created(sessionID: receipt.sessionId, firstMessageError: coreError(error))
      }
    } catch {
      let error = coreError(error)
      phase = error.isDeliveryUncertain ? .uncertain(error) : .failed(error)
    }
  }

  /// Uploads the staged files to `sessionID`, then sends `text` with them. A failure leaves
  /// the session created with the error to retry from the session.
  private func sendWithAttachments(sessionID: String, text: String) async {
    do {
      for attachment in attachments {
        let item = try core.addAttachment(
          sessionId: sessionID, filename: attachment.filename, mediaType: attachment.mediaType,
          data: attachment.data)
        try await core.uploadFirstAttachment(sessionId: sessionID, itemId: item)
      }
      attachments = []
      _ = try await core.sendFirstMessage(sessionId: sessionID, text: text)
      pendingFirstMessage = nil
    } catch {
      phase = .created(sessionID: sessionID, firstMessageError: coreError(error))
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
