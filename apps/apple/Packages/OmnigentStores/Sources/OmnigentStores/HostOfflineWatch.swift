public import Observation
import OmnigentCoreFFI

/// A host that was online and went offline, for the "A runner goes offline" notification.
public struct HostWentOffline: Hashable, Sendable {
  /// The host's id.
  public let hostID: String
  /// Its display name.
  public let name: String

  /// Creates the record.
  /// - Parameters:
  ///   - hostID: The host's id.
  ///   - name: Its display name.
  public init(hostID: String, name: String) {
    self.hostID = hostID
    self.name = name
  }
}

/// Notices hosts going offline between host-list reads (the server pushes `hosts_changed` when
/// a host connects or disconnects). A host seen for the first time never counts, and managed
/// sandboxes are left out: they sleep when idle and wake on the next message.
struct HostOfflineWatch: Equatable {
  private var online: [String: Bool] = [:]

  /// Records `hosts` and returns those that were online at the previous read and are not now.
  /// An empty read (a failed one, or no hosts) keeps the previous state.
  mutating func observe(_ hosts: [CreationHost]) -> [HostWentOffline] {
    guard !hosts.isEmpty else { return [] }
    var wentOffline: [HostWentOffline] = []
    var next: [String: Bool] = [:]
    for host in hosts where host.sandboxProvider == nil {
      let isOnline = host.status == "online"
      next[host.hostId] = isOnline
      if online[host.hostId] == true, !isOnline {
        wentOffline.append(HostWentOffline(hostID: host.hostId, name: host.name))
      }
    }
    online = next
    return wentOffline
  }
}

/// The hosts that went offline since the notifier last took them.
@Observable
public final class OfflineHosts {
  /// Waiting for the notifier, oldest first.
  public private(set) var pending: [HostWentOffline] = []
  @ObservationIgnored private var watch = HostOfflineWatch()

  init() {}

  /// Feeds a host-list read to the watch and queues the hosts that went offline.
  func observe(_ hosts: [CreationHost]) {
    let offline = watch.observe(hosts)
    if !offline.isEmpty { pending.append(contentsOf: offline) }
  }

  /// Hands the pending hosts to the notifier.
  /// - Returns: The hosts, oldest first.
  public func take() -> [HostWentOffline] {
    defer { if !pending.isEmpty { pending = [] } }
    return pending
  }
}
