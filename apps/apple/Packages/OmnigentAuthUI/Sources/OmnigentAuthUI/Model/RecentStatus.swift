import Foundation

/// How the server list shows one recent server: its name, whether it answers, and whether it was
/// the last one used.
public nonisolated struct RecentStatus: Hashable, Sendable {
  /// The row's title: "Local installation (host)" for this Mac, the server's own name beside
  /// its host, or the host.
  public var title: String
  /// Whether it answers, or "Checking…" while unknown.
  public var subtitle: String
  /// Whether ``subtitle`` reports a remote server that does not answer.
  public var isError: Bool
  /// "Last used" on the most recent server.
  public var badge: String?
  /// A laptop for this Mac's servers, a server otherwise.
  public var systemImage: String

  /// The status of `url`.
  /// - Parameters:
  ///   - url: The recent server.
  ///   - reachability: The probe's answer; `nil` while it runs.
  ///   - isLastUsed: Whether it is the most recent server.
  public init(url: String, reachability: ServerReachability?, isLastUsed: Bool) {
    let host = ServerIdentity.hostLabel(url)
    let isLocal = LocalInstall.isLoopback(url)
    if isLocal {
      title = "Local installation (\(host))"
    } else if case .omnigent(let name?) = reachability,
      !name.trimmingCharacters(in: .whitespaces).isEmpty
    {
      title = "\(ServerText.escaped(name, limit: 60)) (\(host))"
    } else {
      title = host
    }
    switch reachability {
    case nil:
      subtitle = "Checking\u{2026}"
      isError = false
    case .omnigent:
      subtitle = isLocal ? "Running" : "Omnigent server"
      isError = false
    case .reachable:
      subtitle = "Reachable"
      isError = false
    case .unreachable:
      subtitle = LocalInstall.isLocalInstall(url) ? "Not running" : "Can\u{2019}t reach"
      isError = !isLocal
    }
    badge = isLastUsed ? "Last used" : nil
    systemImage = isLocal ? "laptopcomputer" : "server.rack"
  }
}
