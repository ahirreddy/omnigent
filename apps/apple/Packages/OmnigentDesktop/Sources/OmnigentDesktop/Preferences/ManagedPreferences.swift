public import Foundation

// MDM Managed Preferences, ported from web/electron/src/managed_preferences.js and
// web/electron/docs/managed-preferences.md. Values are read on demand and never copied into app
// settings, so removing a profile takes effect the next time they are read.

/// Why a managed preference was rejected. The whole value is rejected, never applied in part.
nonisolated public enum ManagedPreferencesError: Error, Equatable, Sendable {
  /// `serverUrls` is not an array of strings.
  case notAnArray(domain: String)
  /// `serverUrls` has more than `ManagedPreferences.maximumServerCount` entries.
  case tooManyServers(domain: String, count: Int)
  /// One entry is not a string, is empty, is malformed or is not https.
  case invalidServer(domain: String, index: Int, reason: String)
  /// `databricksInternalFeaturesEnabled` is present but not a boolean.
  case notABoolean(domain: String, key: String)
}

/// A server offered by the organization.
nonisolated public struct ManagedServer: Hashable, Sendable {
  /// The URL to connect to, path and query preserved, `omnigentServerName` removed.
  public var url: URL
  /// The administrator's display name, if any.
  public var name: String?
  /// The server's origin.
  public var origin: ServerOrigin

  /// The name, or the host when unnamed.
  public var displayName: String { name ?? origin.authority }
}

/// The effective managed configuration and where it came from.
nonisolated public struct ManagedPreferencesSnapshot: Hashable, Sendable {
  /// The domain `serverUrls` was read from, or `nil` when no domain sets it.
  public var serversDomain: String?
  /// Whether an MDM profile forces `serverUrls`, as opposed to a plain `defaults write`.
  public var serversAreForced: Bool
  /// Organization servers, most preferred first.
  public var servers: [ManagedServer]
}

/// Reads and validates organization-provided preferences.
public struct ManagedPreferences {
  /// The array of server URL strings.
  nonisolated public static let serverURLsKey = "serverUrls"
  /// Query parameter naming a server inside a `serverUrls` entry.
  nonisolated public static let serverNameParameter = "omnigentServerName"
  /// Boolean gating Databricks-internal features.
  nonisolated public static let databricksInternalFeaturesKey = "databricksInternalFeaturesEnabled"
  /// Keeps the connect screen's organization list bounded.
  nonisolated public static let maximumServerCount = 10
  /// The native app's domain first, then the Electron app's, so existing profiles keep working.
  nonisolated public static let defaultDomains = ["ai.omnigent.mac", "ai.omnigent.desktop"]

  /// Reads one key from one domain.
  public typealias ValueReader = (_ key: String, _ domain: String) -> Any?
  /// Whether one key in one domain is forced by a profile.
  public typealias ForcedReader = (_ key: String, _ domain: String) -> Bool

  /// Domains in precedence order.
  public let domains: [String]
  private let readValue: ValueReader
  private let readForced: ForcedReader

  /// Creates a reader.
  /// - Parameters:
  ///   - domains: Domains in precedence order. The first that sets a key wins; values are never
  ///     merged across domains. Debug builds can pass `ai.omnigent.mac.lab`.
  ///   - readValue: Defaults to `CFPreferencesCopyAppValue`, which returns forced values first.
  ///   - readForced: Defaults to `CFPreferencesAppValueIsForced`.
  public init(
    domains: [String] = Self.defaultDomains,
    readValue: @escaping ValueReader = { key, domain in
      CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    },
    readForced: @escaping ForcedReader = { key, domain in
      CFPreferencesAppValueIsForced(key as CFString, domain as CFString)
    }
  ) {
    self.domains = domains
    self.readValue = readValue
    self.readForced = readForced
  }

  /// Reads `serverUrls`.
  /// - Returns: The servers, empty when no domain sets the key.
  /// - Throws: `ManagedPreferencesError` when the configured value is invalid. Callers show no
  ///   organization servers and surface the error.
  public func servers() throws(ManagedPreferencesError) -> ManagedPreferencesSnapshot {
    for domain in domains {
      guard let value = readValue(Self.serverURLsKey, domain) else { continue }
      return ManagedPreferencesSnapshot(
        serversDomain: domain,
        serversAreForced: readForced(Self.serverURLsKey, domain),
        servers: try Self.parseServers(value, domain: domain))
    }
    return ManagedPreferencesSnapshot(serversDomain: nil, serversAreForced: false, servers: [])
  }

  /// Reads `databricksInternalFeaturesEnabled`. Only an explicit boolean `true` enables it.
  /// - Returns: Whether the features are enabled.
  /// - Throws: `ManagedPreferencesError.notABoolean` for numbers, strings and other types.
  public func databricksInternalFeaturesEnabled() throws(ManagedPreferencesError) -> Bool {
    for domain in domains {
      guard let value = readValue(Self.databricksInternalFeaturesKey, domain) else { continue }
      guard Self.isCFBoolean(value), let flag = value as? Bool else {
        throw .notABoolean(domain: domain, key: Self.databricksInternalFeaturesKey)
      }
      return flag
    }
    return false
  }

  /// Validates a `serverUrls` value as one configuration.
  /// - Parameters:
  ///   - value: The raw property-list value.
  ///   - domain: The domain, for error messages.
  /// - Returns: Servers deduplicated by origin, first occurrence kept.
  /// - Throws: `ManagedPreferencesError` for a wrong type, an invalid entry or too many entries.
  nonisolated public static func parseServers(_ value: Any, domain: String)
    throws(ManagedPreferencesError) -> [ManagedServer]
  {
    guard let entries = value as? [Any] else { throw .notAnArray(domain: domain) }
    guard entries.count <= maximumServerCount else {
      throw .tooManyServers(domain: domain, count: entries.count)
    }
    var servers: [ManagedServer] = []
    var origins: Set<ServerOrigin> = []
    for (index, entry) in entries.enumerated() {
      guard let text = entry as? String else {
        throw .invalidServer(domain: domain, index: index, reason: "is not a string")
      }
      let server: ManagedServer
      do {
        server = try parseServer(text)
      } catch {
        throw .invalidServer(domain: domain, index: index, reason: error.reason)
      }
      guard origins.insert(server.origin).inserted else { continue }
      servers.append(server)
    }
    return servers
  }

  /// Normalizes one entry. A schemeless host becomes https; the path and other query items are
  /// kept byte for byte; `omnigentServerName` becomes the display name.
  /// - Parameter text: The entry.
  /// - Returns: The server.
  /// - Throws: `ManagedServerEntryError` describing the problem.
  nonisolated public static func parseServer(_ text: String) throws(ManagedServerEntryError)
    -> ManagedServer
  {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ManagedServerEntryError("is empty") }
    let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard var components = URLComponents(string: withScheme) else {
      throw ManagedServerEntryError("is not a valid URL")
    }
    guard components.scheme?.lowercased() == "https" else {
      throw ManagedServerEntryError("must use https://")
    }
    guard components.user == nil, components.password == nil else {
      throw ManagedServerEntryError("must not contain credentials")
    }
    guard let host = components.percentEncodedHost, !host.isEmpty else {
      throw ManagedServerEntryError("has no host")
    }
    let origin: ServerOrigin
    do {
      origin = try ServerOrigin(scheme: .https, host: host, port: components.port)
    } catch {
      throw ManagedServerEntryError("has an invalid host or port (\(error))")
    }
    components.scheme = "https"
    components.percentEncodedHost = origin.host
    components.port = origin.port
    if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }

    let name = extractServerName(from: &components)
    guard let url = components.url else { throw ManagedServerEntryError("is not a valid URL") }
    return ManagedServer(url: url, name: name, origin: origin)
  }

  /// Drops recent servers whose origin an organization server already covers. Entries that are
  /// not valid http(s) URLs are kept so the caller's own validation can report them.
  /// - Parameters:
  ///   - recents: The user's recent server URLs.
  ///   - managed: The organization's servers.
  /// - Returns: The remaining recents, order preserved.
  nonisolated public static func excludingManaged(_ recents: [URL], managed: [ManagedServer])
    -> [URL]
  {
    let managedOrigins = Set(managed.map(\.origin))
    return recents.filter { recent in
      do {
        return !managedOrigins.contains(try ServerOrigin(url: recent))
      } catch {
        return true
      }
    }
  }

  /// Removes every `omnigentServerName` item, leaving the others byte for byte, and returns the
  /// first one's trimmed value. The query is only rewritten when the parameter is present.
  nonisolated private static func extractServerName(from components: inout URLComponents)
    -> String?
  {
    guard let query = components.percentEncodedQuery else { return nil }
    let pairs = query.split(separator: "&", omittingEmptySubsequences: false)
    var kept: [Substring] = []
    var names: [String] = []
    for pair in pairs {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard let rawName = parts.first, formDecoded(rawName) == serverNameParameter else {
        kept.append(pair)
        continue
      }
      names.append(parts.dropFirst().first.flatMap(formDecoded) ?? "")
    }
    guard kept.count != pairs.count else { return nil }
    components.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
    let name = names.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return name.isEmpty ? nil : name
  }

  /// Property lists bridge booleans and numbers to `NSNumber`, so `as? Bool` alone would accept
  /// `1`. Only a real `CFBoolean` counts.
  nonisolated private static func isCFBoolean(_ value: Any) -> Bool {
    CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
  }

  nonisolated private static func formDecoded(_ text: Substring) -> String? {
    text.replacing("+", with: " ").removingPercentEncoding
  }
}

/// Why one `serverUrls` entry was rejected.
nonisolated public struct ManagedServerEntryError: Error, Equatable, Sendable {
  /// Human-readable reason, for example "must use https://".
  public let reason: String

  init(_ reason: String) {
    self.reason = reason
  }
}
