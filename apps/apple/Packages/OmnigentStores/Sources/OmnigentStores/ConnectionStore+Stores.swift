public import Foundation
public import OmnigentCoreFFI

extension ConnectionStore {
  /// Starts a Databricks workspace sign-in. With a loopback client, pass the port the local
  /// listener bound and open ``databricksChallenge``'s `authorizeUrl` in the system browser;
  /// otherwise present it in the sign-in sheet, intercepting the HTTPS callback at its callback
  /// host and path.
  /// - Parameter loopbackPort: The listener's port for a loopback client, else `nil`.
  /// - Returns: The challenge, or `nil` after recording the failure.
  @discardableResult
  public func beginDatabricksSignIn(loopbackPort: UInt16? = nil) -> DatabricksChallenge? {
    guard let core else { return nil }
    do {
      let challenge = try core.beginDatabricksSignIn(loopbackPort: loopbackPort)
      databricksChallenge = challenge
      return challenge
    } catch {
      record(scope: .connection, coreError(error))
      return nil
    }
  }

  /// Finishes a Databricks sign-in with the callback the sheet intercepted.
  /// - Parameters:
  ///   - challenge: The challenge from ``beginDatabricksSignIn(loopbackPort:)``.
  ///   - callbackURL: The full callback URL.
  /// - Returns: The server signed in to, or `nil` after recording the failure or when the
  ///   sign-in was cancelled. It can return before ``phase`` reads `connected`.
  public func completeDatabricksSignIn(_ challenge: DatabricksChallenge, callbackURL: URL) async
    -> ConnectedServer?
  {
    guard let core else { return nil }
    if databricksChallenge?.attemptId == challenge.attemptId { databricksChallenge = nil }
    do {
      return try await core.completeDatabricksSignIn(
        attemptId: challenge.attemptId, callbackUrl: callbackURL.absoluteString)
    } catch {
      let error = coreError(error)
      if !error.isCancellation { record(scope: .connection, error) }
      return nil
    }
  }

  /// Abandons a Databricks sign-in (the sheet closed or could not be presented).
  /// - Parameter challenge: The challenge.
  public func cancelDatabricksSignIn(_ challenge: DatabricksChallenge) {
    if databricksChallenge?.attemptId == challenge.attemptId { databricksChallenge = nil }
    core?.cancelDatabricksSignIn(attemptId: challenge.attemptId)
  }

  /// Reads which top-level pages the server offers; a failure is recorded in ``issues`` and
  /// leaves them unoffered.
  public func loadOfferedPages() async {
    guard let pages, let error = await pages.loadOffered() else { return }
    record(scope: .connection, error)
  }

  /// The new-session form's store, created on first use.
  /// - Returns: The store, or `nil` when the core did not start.
  public func creation() -> CreationStore? {
    if let creationStore { return creationStore }
    guard let core else { return nil }
    let store = CreationStore(core: core)
    creationStore = store
    return store
  }

  /// The workspace (files, search, changes, diffs) of `sessionID`, created on first use.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - environmentID: The environment, `default` unless the session has others.
  /// - Returns: The store, or `nil` when the core did not start.
  public func workspace(_ sessionID: String, environmentID: String = "default") -> WorkspaceStore? {
    if let existing = workspaceStores[sessionID], existing.environmentID == environmentID {
      return existing
    }
    guard let core else { return nil }
    let store = WorkspaceStore(sessionID: sessionID, environmentID: environmentID, core: core)
    workspaceStores[sessionID] = store
    return store
  }

  /// The terminal list of `sessionID`, created on first use. It is kept current while the
  /// session is open (see ``conversation(_:)``).
  /// - Parameter sessionID: The session.
  /// - Returns: The store, or `nil` when the core did not start.
  public func terminals(_ sessionID: String) -> SessionTerminalsStore? {
    if let existing = terminalStores[sessionID] { return existing }
    guard let core else { return nil }
    let store = SessionTerminalsStore(sessionID: sessionID, core: core)
    terminalStores[sessionID] = store
    return store
  }
}
