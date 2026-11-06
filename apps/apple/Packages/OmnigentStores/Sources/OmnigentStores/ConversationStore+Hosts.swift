public import OmnigentCoreFFI

/// Moving the session's runner between hosts, and the live sign-in its terminal waits on.
extension ConversationStore {
  /// The server's hosts, for Switch Host and Resume on a Machine.
  /// - Returns: The hosts.
  /// - Throws: The core's read error.
  public func hosts() async throws(CoreError) -> [CreationHost] {
    do {
      return try await core.hosts()
    } catch {
      throw coreError(error)
    }
  }

  /// A folder on `hostID` (its home when `path` is `nil`), for the folder browser and the
  /// default directory.
  /// - Parameters:
  ///   - hostID: The host.
  ///   - path: An absolute folder, or `nil` for the home.
  /// - Returns: The listing.
  /// - Throws: The core's read error.
  public func hostDirectory(hostID: String, path: String?) async throws(CoreError)
    -> HostDirectoryListing
  {
    do {
      return try await core.hostDirectory(hostId: hostID, path: path)
    } catch {
      throw coreError(error)
    }
  }

  /// Moves the session to `hostID`, starting its runner in `workspace` there.
  /// - Parameters:
  ///   - hostID: An online host.
  ///   - workspace: An absolute directory on it.
  /// - Returns: The launch; `failed` means the old host was released and the session now runs
  ///   nowhere.
  /// - Throws: The core's error when nothing moved.
  public func switchHost(to hostID: String, workspace: String) async throws(CoreError)
    -> RunnerLaunch
  {
    do {
      return try await core.switchSessionHost(
        sessionId: sessionID, hostId: hostID, workspace: workspace)
    } catch {
      throw coreError(error)
    }
  }

  /// Starts the session, bound to no host, on `hostID` in `workspace`.
  /// - Parameters:
  ///   - hostID: An online host.
  ///   - workspace: An absolute directory on it.
  ///   - git: A new worktree to start in, when it names a branch.
  /// - Throws: The core's error.
  public func resume(onHost hostID: String, workspace: String, git: CreationGit?)
    async throws(CoreError)
  {
    do {
      _ = try await core.resumeSessionOnHost(
        sessionId: sessionID, hostId: hostID, workspace: workspace, git: git)
    } catch {
      throw coreError(error)
    }
  }

  /// The sign-in the session's terminal waits on now.
  /// - Returns: The link and code, or not pending.
  /// - Throws: The core's read error (the host unreachable included).
  public func signInLink() async throws(CoreError) -> SessionSignInLink {
    do {
      return try await core.sessionSignInLink(sessionId: sessionID)
    } catch {
      throw coreError(error)
    }
  }
}
