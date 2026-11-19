public import Observation
public import OmnigentCoreFFI

/// Whether the server can be reached: the one state every connection warning shows.
public enum ServerReachability: Equatable, Sendable {
  /// Live, or nothing to report (signed out, or the first connect still in flight).
  case online
  /// The live connection dropped and at least one attempt to restore it failed; the core keeps
  /// trying.
  case reconnecting(reason: CoreError, failures: UInt32)
  /// The server could not be reached when connecting; this device's saved copy shows.
  case offline
  /// The live connection stopped retrying for a reason other than sign-in; the next network
  /// change, wake or Retry tries again.
  case unreachable(CoreError)

  /// Whether a warning is on screen.
  public var isDisrupted: Bool { self != .online }
}

/// What one observation of the connection says, before history is taken into account.
enum ReachabilitySignal: Equatable {
  /// Live: whatever went wrong is over.
  case reachable
  /// Neither live nor known to be down: connecting, or a healthy socket recycling.
  case unsettled
  /// Down, as the warning should say.
  case disrupted(ServerReachability)
}

/// Follows one server's connection so its warnings clear once it is back, and says when that
/// return is one the user could have noticed. A first connect, a healthy socket recycle and a
/// switch to another server are never recoveries.
struct ConnectionRecovery: Equatable {
  /// The server observed, normalized; a different one starts over.
  private(set) var server: String?
  /// The disruption on screen, `nil` while there is none.
  private(set) var disruption: ServerReachability?

  /// What the warnings show.
  var reachability: ServerReachability { disruption ?? .online }

  /// Applies one observation.
  /// - Parameters:
  ///   - server: The server shown, or `nil` when none is (signed out, sign-in screen).
  ///   - signal: What the connection says now.
  /// - Returns: Whether this observation ends a disruption: the moment to clear warnings, read
  ///   again what changed and say the connection is back.
  mutating func observe(server: String?, signal: ReachabilitySignal) -> Bool {
    let normalized = server.map(Self.normalized)
    if normalized != self.server {
      self.server = normalized
      disruption = nil
    }
    guard normalized != nil else { return false }
    switch signal {
    case .reachable:
      guard disruption != nil else { return false }
      disruption = nil
      return true
    case .unsettled:
      return false
    case .disrupted(let reachability):
      disruption = reachability
      return false
    }
  }

  /// A server URL compared without case, scheme or trailing slash: the address typed and the
  /// canonical one the connect confirms name the same server.
  static func normalized(_ server: String) -> String {
    var trimmed = server.lowercased()
    for scheme in ["https://", "http://"] where trimmed.hasPrefix(scheme) {
      trimmed.removeFirst(scheme.count)
    }
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    return trimmed
  }
}

/// The connection's reachability, as every warning shows it, and the brief "Reconnected" once it
/// is back. Its own object, so only the views that show it follow it.
@Observable
public final class ConnectionHealth {
  /// How long "Reconnected" shows.
  public static let reconnectedNoticeDuration: Duration = .seconds(2)

  /// What the connection warnings show.
  public private(set) var reachability: ServerReachability = .online
  /// "Reconnected" shows: the connection came back after a disruption the user could see.
  public private(set) var showsReconnected = false
  /// How many times the connection came back; a read keyed on it runs again.
  public private(set) var reconnections = 0
  @ObservationIgnored private var recovery = ConnectionRecovery()
  @ObservationIgnored var noticeDuration = ConnectionHealth.reconnectedNoticeDuration
  @ObservationIgnored private var noticeTask: Task<Void, Never>?

  /// Creates a health with nothing observed.
  public init() {}

  isolated deinit {
    noticeTask?.cancel()
  }

  /// Applies one observation of the connection.
  /// - Parameters:
  ///   - server: The server shown, `nil` when none is.
  ///   - signal: What the connection says now.
  /// - Returns: Whether it ends a disruption.
  func observe(server: String?, signal: ReachabilitySignal) -> Bool {
    let before = recovery
    let recovered = recovery.observe(server: server, signal: signal)
    if recovery.reachability != reachability { reachability = recovery.reachability }
    if reachability.isDisrupted || recovery.server != before.server { hideReconnected() }
    guard recovered else { return false }
    reconnections += 1
    showReconnected()
    return true
  }

  private func showReconnected() {
    showsReconnected = true
    noticeTask?.cancel()
    let duration = noticeDuration
    noticeTask = Task { [weak self] in
      await sleepUnlessCancelled(for: duration)
      guard !Task.isCancelled, let self else { return }
      showsReconnected = false
    }
  }

  private func hideReconnected() {
    noticeTask?.cancel()
    noticeTask = nil
    if showsReconnected { showsReconnected = false }
  }
}
