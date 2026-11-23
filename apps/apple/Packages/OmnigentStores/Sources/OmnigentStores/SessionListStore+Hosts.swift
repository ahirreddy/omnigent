import OmnigentCoreFFI

/// The host reads a session list asks for.
struct SessionListHostReads {
  /// Re-reads the hosts; set by the owning ``ConnectionStore``.
  var reload: () -> Void = {}
  /// The hosts were read since connecting.
  var hasRead = false
  /// Unlisted hosts of owned sessions a re-read was asked for, so each asks once.
  var askedFor: Set<String> = []
}

extension SessionListStore {
  /// Re-reads the hosts and where a session on each runs.
  /// - Parameter serverURL: The connected server, which decides whether a host is this Mac.
  /// - Returns: The hosts; none when the read failed (``hostsError``).
  @discardableResult
  public func loadHosts(serverURL: String) async -> [CreationHost] {
    guard let core else { return [] }
    do {
      let hosts = try await core.hosts()
      let environments = OmnigentCoreFFI.hostEnvironments(
        hosts: hosts, serverUrl: serverURL, thisMachineHostId: thisMachineHostID())
      let byID = Dictionary(
        environments.map { ($0.hostId, $0.environment) }, uniquingKeysWith: { first, _ in first })
      if byID != hostEnvironments { hostEnvironments = byID }
      hostReads.hasRead = true
      hostsError = nil
      return hosts
    } catch {
      hostsError = coreError(error)
      return []
    }
  }

  /// Re-reads the hosts when an owned session names one the last read did not list. A server
  /// tells only clients on its own replica of a new host, such as a new session's sandbox.
  func askForUnlistedHosts(_ sessions: [SessionSummary]) {
    guard hostReads.hasRead else { return }
    let unlisted = Set(
      sessions.compactMap { session -> String? in
        guard isOwned(session), let host = session.configuration?.hostId, !host.isEmpty,
          hostEnvironments[host] == nil
        else { return nil }
        return host
      }
    ).subtracting(hostReads.askedFor)
    guard !unlisted.isEmpty else { return }
    hostReads.askedFor.formUnion(unlisted)
    hostReads.reload()
  }
}
