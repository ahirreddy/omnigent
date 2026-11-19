public import OmnigentCoreFFI

/// The connection's one reachability state, and what its return clears and reads again.
extension ConnectionStore {
  /// Clears ``issues`` after the user has seen them.
  public func dismissIssues() {
    issues = []
  }

  /// What the connection says now. The updates socket proves the server reachable; a socket
  /// that recycles after a healthy run (no failed attempt yet) is not a disruption.
  var reachabilitySignal: ReachabilitySignal {
    if isOffline { return .disrupted(.offline) }
    if case .failed(_, let error) = phase, error.isConnectivityProblem {
      return .disrupted(.unreachable(error))
    }
    guard isSignedIn else { return .unsettled }
    switch updatesLink {
    case .live:
      return .reachable
    case .reconnecting(let reason, let failures, _):
      return failures > 0
        ? .disrupted(.reconnecting(reason: reason, failures: failures)) : .unsettled
    case .failed(let error):
      // A sign-in failure leaves for the sign-in screen, which says so itself.
      return error.requiresSignIn ? .unsettled : .disrupted(.unreachable(error))
    case .idle, .connecting, .closed, .stopped:
      return .unsettled
    }
  }

  /// The server the connection is about, through a reconnect's discovery and connect, so a return
  /// is told from a switch; `nil` while signed out or signing in, which start over.
  var reachabilityServer: String? {
    if let offlineServerURL { return offlineServerURL }
    switch phase {
    case .discovering(let serverURL), .failed(let serverURL, _): return serverURL
    case .connecting(let baseURL): return baseURL
    case .connected(let server): return server.baseUrl
    case .disconnected, .signInRequired, .signingIn, .awaitingBrowserLogin: return nil
    }
  }

  /// Follows the connection after an event that may change it; its return clears what it left.
  func observeReachability() {
    guard health.observe(server: reachabilityServer, signal: reachabilitySignal) else { return }
    connectionRecovered()
  }

  /// The connection is back after a disruption: failures that only said the server could not be
  /// reached go, and what may have changed while away is read again. Any other failure, such as
  /// an expired sign-in or a refused action, stays until dismissed.
  func connectionRecovered() {
    issues.removeAll { $0.error.isConnectivityProblem }
    if let id = offeredPagesIssueID, !issues.contains(where: { $0.id == id }) {
      offeredPagesIssueID = nil
    }
    sessionList.connectionRecovered()
    for conversation in conversations.values { conversation.connectionRecovered() }
    // File changes pushed while away are not replayed: each open workspace reads its files again.
    for open in workspaceStores.keys {
      withMutation(keyPath: \.[fileChangesIn: open]) { fileChangeCounts[open, default: 0] += 1 }
    }
    // The core reads the list, the projects and the hosts again as its socket resumes; session
    // streams still waiting out their backoff redial now, and the offered pages are read again.
    foreground()
  }
}

extension CoreError {
  /// Whether this failure only says the server could not be reached, which reconnecting fixes:
  /// the core's unreachable failures, and live links lost for any reason but sign-in. A write
  /// whose delivery is uncertain is not one; the user must review it.
  public var isConnectivityProblem: Bool {
    switch self {
    case .Transport(let kind, _):
      return kind != .cancelled
    case .HttpStatus(let status, _):
      return (502...504).contains(status)
    case .Link(let kind, _, let requiresSignIn):
      // A 404 may mean the session is gone, which reconnecting does not fix.
      return !requiresSignIn && kind != .notFound
    case .Session(let kind, _, _, let requiresSignIn, let deliveryUncertain):
      return !requiresSignIn && !deliveryUncertain
        && [SessionErrorKind.transport, .offline, .notConnected].contains(kind)
    case .Auth(_, let failure, _, _), .Oidc(_, let failure, _):
      return failure == .transport
    default:
      return false
    }
  }
}
