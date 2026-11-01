public import Foundation

/// A remembered permission decision.
nonisolated public enum BrowserPermissionDecision: String, Sendable, Hashable, Codable {
  /// Granted.
  case allow
  /// Denied.
  case deny
}

/// Permission decisions per profile and origin. Persistent profiles keep them in
/// `UserDefaults` (one dictionary per profile storage key); ephemeral profiles keep them in
/// memory for the life of the store, so an agent run never leaves decisions behind.
public final class BrowserPermissionStore {
  /// Prefix of the per-profile `UserDefaults` keys.
  public static let defaultsKeyPrefix = "ai.omnigent.browser.permissions."

  /// The app-wide store.
  public static let shared = BrowserPermissionStore()

  private let defaults: UserDefaults
  private var ephemeral: [String: [String: BrowserPermissionDecision]] = [:]

  /// Creates a store over `defaults`.
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The remembered decision covering every permission in `permissions`, or nil when any of
  /// them is undecided. A deny for any of them denies the request.
  public func decision(
    for permissions: BrowserPermissions, origin: String, profile: BrowserProfile
  ) -> BrowserPermissionDecision? {
    let stored = decisions(for: profile)
    var allAllowed = true
    for (permission, _) in BrowserPermissions.named where permissions.contains(permission) {
      switch stored[Self.key(origin: origin, permission: permission)] {
      case .deny: return .deny
      case .allow: continue
      case nil: allAllowed = false
      }
    }
    return allAllowed && !permissions.isEmpty ? .allow : nil
  }

  /// Remembers `decision` for each permission in `permissions`.
  public func record(
    _ decision: BrowserPermissionDecision, for permissions: BrowserPermissions, origin: String,
    profile: BrowserProfile
  ) {
    var stored = decisions(for: profile)
    for (permission, _) in BrowserPermissions.named where permissions.contains(permission) {
      stored[Self.key(origin: origin, permission: permission)] = decision
    }
    save(stored, for: profile)
  }

  /// Every remembered decision for a profile, keyed "origin|permission bit".
  public func decisions(for profile: BrowserProfile) -> [String: BrowserPermissionDecision] {
    switch profile.persistence {
    case .ephemeral:
      return ephemeral[profile.identifier] ?? [:]
    case .persistent:
      let raw = defaults.dictionary(forKey: Self.defaultsKey(profile)) as? [String: String] ?? [:]
      return raw.compactMapValues(BrowserPermissionDecision.init(rawValue:))
    }
  }

  /// Forgets one remembered decision ("origin|permission bit" key from `decisions(for:)`).
  public func forget(key: String, profile: BrowserProfile) {
    var stored = decisions(for: profile)
    stored[key] = nil
    save(stored, for: profile)
  }

  /// Forgets a profile's decisions.
  public func reset(profile: BrowserProfile) {
    switch profile.persistence {
    case .ephemeral: ephemeral[profile.identifier] = nil
    case .persistent: defaults.removeObject(forKey: Self.defaultsKey(profile))
    }
  }

  /// `scheme://host[:port]` of `url`, lowercase; the unit decisions are kept for.
  public static func origin(of url: URL?) -> String {
    guard let url, let scheme = url.scheme?.lowercased() else { return "" }
    let host = url.host(percentEncoded: false)?.lowercased() ?? ""
    let port = url.port.map { ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)"
  }

  private func save(_ stored: [String: BrowserPermissionDecision], for profile: BrowserProfile) {
    switch profile.persistence {
    case .ephemeral:
      ephemeral[profile.identifier] = stored
    case .persistent:
      defaults.set(stored.mapValues(\.rawValue), forKey: Self.defaultsKey(profile))
    }
  }

  private static func defaultsKey(_ profile: BrowserProfile) -> String {
    defaultsKeyPrefix + profile.storageKey
  }

  private static func key(origin: String, permission: BrowserPermissions) -> String {
    "\(origin)|\(permission.rawValue)"
  }
}
