public import OmnigentCoreFFI

/// The core calls one creation makes, by what goes with it.
struct CreationCalls {
  /// Creates the session for a first message sent next, after its attachments upload.
  let forMessage: (ClientCore) async throws -> CreationReceipt
  /// Creates the session with no first message.
  let bare: (ClientCore) async throws -> CreationReceipt
  /// Creates the session and sends the first message.
  let andSend: (ClientCore) async throws -> CreatedSession
}

extension CreationStore {
  /// The worktrees of the repository at `path` on `hostID`; empty when it isn't one.
  /// - Parameters:
  ///   - hostID: The host.
  ///   - path: An absolute folder.
  /// - Returns: The worktrees, or why they could not be read.
  public func worktrees(hostID: String, path: String) async -> Result<[HostWorktree], CoreError> {
    do {
      return .success(try await core.hostWorktrees(hostId: hostID, path: path))
    } catch {
      return .failure(coreError(error))
    }
  }

  /// Leaves `text` in a created session's composer instead of sending it, as a planning chat's
  /// prompt waits there for the user (web `sideChatDrafts`).
  public func leaveDraft(_ text: String, inSession sessionID: String) {
    conversation?(sessionID)?.composer.text = text
  }

  /// Creates the session, then sends `firstMessage` to it when it is not blank. Creation is
  /// never retried: an unclear outcome becomes ``CreationPhase/uncertain(_:)``. Staged files
  /// are uploaded to the new session and sent with the first message.
  /// - Parameters:
  ///   - selection: Host, agent, workspace and model.
  ///   - title: The session name; may be empty.
  ///   - firstMessage: The first message; may be empty.
  public func create(_ selection: CreationSelection, title: String, firstMessage: String) async {
    await create(
      firstMessage: firstMessage,
      CreationCalls(
        forMessage: { core in
          try await core.createSessionForMessage(
            selection: selection, title: title, text: firstMessage)
        },
        bare: { core in try await core.createSession(selection: selection, title: title) },
        andSend: { core in
          try await core.createSessionAndSend(
            selection: selection, title: title, text: firstMessage)
        }))
  }
}
