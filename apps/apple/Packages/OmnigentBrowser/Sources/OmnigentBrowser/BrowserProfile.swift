internal import CryptoKit
public import Foundation

/// Storage identity for browser tabs. Tabs with equal profiles share cookies, local storage and
/// cache; different profiles are fully isolated. Use one persistent profile per server.
nonisolated public struct BrowserProfile: Hashable, Sendable {
  /// How long profile data lives.
  public enum Persistence: Hashable, Sendable {
    /// Stored on disk and kept across launches.
    case persistent
    /// Kept in memory for the life of the process.
    case ephemeral
  }

  /// Caller-chosen identity, for example a server ID or origin.
  public let identifier: String
  /// Whether data survives relaunch.
  public let persistence: Persistence

  /// Creates a profile.
  public init(identifier: String, persistence: Persistence) {
    self.identifier = identifier
    self.persistence = persistence
  }

  /// A persistent profile scoped to one Omnigent server.
  public static func server(_ serverID: String) -> Self {
    Self(identifier: "server:\(serverID)", persistence: .persistent)
  }

  /// An in-memory profile, for example for one agent conversation.
  public static func ephemeral(_ identifier: String) -> Self {
    Self(identifier: identifier, persistence: .ephemeral)
  }

  private var digest: SHA256.Digest {
    SHA256.hash(data: Data(identifier.utf8))
  }

  /// Filesystem-safe directory name derived from the identifier.
  public var storageKey: String {
    digest.prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  /// Deterministic UUID for `WKWebsiteDataStore(forIdentifier:)`, with RFC 9562 version 8 and
  /// variant bits set.
  public var dataStoreIdentifier: UUID {
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x80
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}
