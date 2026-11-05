import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The session's liveness line under the composer, from the header's runner and host signals
/// and the runner-offline answers of its terminal reads.
enum LivenessAdapter {
  /// The notice, `nil` while the agent is online, unknown, or the session is read-only.
  /// - Parameters:
  ///   - store: The conversation.
  ///   - serverURL: The connected server, for the reconnect command.
  /// - Returns: The notice.
  static func notice(_ store: ConversationStore, serverURL: String?) -> SessionLivenessNotice? {
    guard let header = store.header, !header.readOnly, !header.archived, !store.isClosed else {
      return nil
    }
    let liveness = liveness(header, runnerUnavailable: store.runnerUnavailable != nil)
    switch liveness {
    case .online, .unknown: return nil
    default: break
    }
    return SessionLivenessNotice(
      liveness: liveness, sessionID: store.sessionID, serverURL: serverURL ?? "",
      wrapper: header.settings?.wrapper, harness: header.settings?.harness)
  }

  /// The liveness of a session with `header`.
  /// - Parameters:
  ///   - header: The session header.
  ///   - runnerUnavailable: A terminal read found the runner offline.
  /// - Returns: The liveness.
  static func liveness(
    _ header: OmnigentCoreFFI.SessionHeader, runnerUnavailable: Bool
  ) -> SessionLiveness {
    let settings = header.settings
    // Owners hold level 4 or above; an unshared session reports no level.
    let isOwner = header.permissionLevel.map { $0 >= 4 } ?? true
    var signals = SessionLiveness.Signals(
      runnerOnline: settings?.runnerOnline ?? (runnerUnavailable ? false : nil),
      hostOnline: settings?.hostOnline, hostID: settings?.hostId)
    signals.hostResumable = settings?.hostResumable ?? false
    signals.isTurnActive = header.status == .running
    signals.isSubagent = settings?.parentId != nil
    signals.isOwner = isOwner
    return SessionLiveness.derive(signals)
  }
}
