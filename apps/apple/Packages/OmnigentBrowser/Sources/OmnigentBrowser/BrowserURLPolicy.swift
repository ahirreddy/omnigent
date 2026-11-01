internal import Darwin
public import Foundation

/// A URL policy hook for tabs, used by `AgentBrowserController`: where an agent may navigate.
///
/// Engines enforce `rules` for every navigation in the tab, including redirects and navigations
/// the page starts (Chromium in the web host's `OnBeforeBrowse`, WebKit in
/// `decidePolicyFor navigationAction`). `evaluate(_:)` is the final word for navigations the
/// agent requests and, on WebKit, for every navigation; override it for checks rules cannot
/// express. See OmnigentWebLayer/DESIGN.md, "Agent browser actions".
nonisolated public protocol BrowserURLPolicy: Sendable {
  /// Declarative rules the engine enforces itself.
  var rules: BrowserURLRules { get }
  /// Whether `url` may load.
  func evaluate(_ url: URL) -> BrowserURLDecision
}

extension BrowserURLPolicy {
  /// The rules' decision.
  public func evaluate(_ url: URL) -> BrowserURLDecision {
    rules.evaluate(url)
  }
}

/// A policy decision.
nonisolated public enum BrowserURLDecision: Sendable, Hashable {
  /// The URL may load.
  case allow
  /// The URL may not load, and why.
  case deny(String)
}

/// Allow and deny lists plus scheme and address checks. Matches the web host's
/// `NavigationRules` (WebHost/Sources/OWLNavigationRules.mm) rule for rule:
/// - `about:blank` and `about:srcdoc` always load.
/// - The scheme must be in `schemes` (when not empty).
/// - A host on `deny` is blocked; a pattern matches the host and its subdomains.
/// - Loopback hosts are blocked when `blockPrivateAddresses` is set and `allowLoopback` is not.
/// - Other IP literals outside public unicast space are blocked when `blockPrivateAddresses` is
///   set. Names are not resolved.
/// - When `allow` is not empty, the host must match it (loopback passes with `allowLoopback`).
nonisolated public struct BrowserURLRules: BrowserURLPolicy, Codable, Hashable {
  /// Allowed schemes, lowercase.
  public var schemes: [String]
  /// Allowed host patterns; empty allows every host the other rules allow.
  public var allow: [String]
  /// Blocked host patterns. Deny wins over allow.
  public var deny: [String]
  /// Blocks private, link-local, loopback and reserved IP literals.
  public var blockPrivateAddresses: Bool
  /// Allows localhost and loopback addresses despite `blockPrivateAddresses` and `allow`.
  public var allowLoopback: Bool

  /// Creates rules. The defaults suit agents: web schemes only, no private addresses.
  public init(
    schemes: [String] = ["http", "https"], allow: [String] = [], deny: [String] = [],
    blockPrivateAddresses: Bool = true, allowLoopback: Bool = false
  ) {
    self.schemes = schemes.map { $0.lowercased() }
    self.allow = allow
    self.deny = deny
    self.blockPrivateAddresses = blockPrivateAddresses
    self.allowLoopback = allowLoopback
  }

  /// Rules that allow everything.
  public static let unrestricted = Self(schemes: [], blockPrivateAddresses: false)

  /// Itself.
  public var rules: Self { self }

  /// See the type documentation for the order of checks.
  public func evaluate(_ url: URL) -> BrowserURLDecision {
    let text = url.absoluteString
    if text == "about:blank" || text == "about:srcdoc" {
      return .allow
    }
    let scheme = url.scheme?.lowercased() ?? ""
    if !schemes.isEmpty, !schemes.contains(scheme) {
      return .deny("The scheme \"\(scheme)\" is not allowed.")
    }
    let host = Self.unbracketed(url.host(percentEncoded: false)?.lowercased() ?? "")
    if deny.contains(where: { Self.host(host, matches: $0) }) {
      return .deny("The host \(host) is on the deny list.")
    }
    let loopback = Self.isLoopback(host)
    if loopback, !allowLoopback, blockPrivateAddresses {
      return .deny("Loopback hosts are not allowed.")
    }
    if !loopback, blockPrivateAddresses, Self.isPrivateAddressLiteral(host) {
      return .deny("The private address \(host) is not allowed.")
    }
    if !allow.isEmpty, !allow.contains(where: { Self.host(host, matches: $0) }),
      !(loopback && allowLoopback)
    {
      return .deny("The host \(host) is not on the allow list.")
    }
    return .allow
  }

  /// Whether `host` is `pattern` or one of its subdomains. A leading "*." or "." is ignored.
  public static func host(_ host: String, matches pattern: String) -> Bool {
    var normalized = pattern.lowercased()
    if normalized.hasPrefix("*.") {
      normalized.removeFirst(2)
    } else if normalized.hasPrefix(".") {
      normalized.removeFirst()
    }
    guard !normalized.isEmpty else { return false }
    let lower = host.lowercased()
    return lower == normalized || lower.hasSuffix("." + normalized)
  }

  /// "localhost", its subdomains, 127.0.0.0/8 and ::1.
  public static func isLoopback(_ host: String) -> Bool {
    let lower = unbracketed(host.lowercased())
    if lower == "localhost" || lower.hasSuffix(".localhost") {
      return true
    }
    let octets = ipv4(lower)
    if !octets.isEmpty {
      return octets[0] == 127
    }
    let bytes = ipv6(lower)
    return !bytes.isEmpty && bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1
  }

  /// IP literals outside public unicast space.
  public static func isPrivateAddressLiteral(_ host: String) -> Bool {
    let lower = unbracketed(host.lowercased())
    let octets = ipv4(lower)
    if !octets.isEmpty {
      return isPrivate(octets)
    }
    let bytes = ipv6(lower)
    guard !bytes.isEmpty else { return false }
    if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
      return isPrivate(Array(bytes[12..<16]))
    }
    if bytes[0] & 0xE0 != 0x20 {
      return true  // Only 2000::/3 is global unicast.
    }
    return bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0D && bytes[3] == 0xB8
  }

  private static func isPrivate(_ octets: [UInt8]) -> Bool {
    let (first, second, third) = (octets[0], octets[1], octets[2])
    switch (first, second) {
    case (0, _), (10, _), (127, _), (169, 254), (192, 168): return true
    case (100, 64...127), (172, 16...31), (198, 18...19): return true
    default: break
    }
    if (first, second) == (192, 0), third == 0 || third == 2 { return true }
    if (first, second, third) == (198, 51, 100) || (first, second, third) == (203, 0, 113) {
      return true
    }
    return first >= 224
  }

  private static func unbracketed(_ host: String) -> String {
    host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
  }

  /// The address bytes, or empty when `host` is not an IPv4 literal.
  private static func ipv4(_ host: String) -> [UInt8] {
    var address = in_addr()
    guard inet_pton(AF_INET, host, &address) == 1 else { return [] }
    return withUnsafeBytes(of: address.s_addr) { Array($0) }
  }

  /// The address bytes, or empty when `host` is not an IPv6 literal.
  private static func ipv6(_ host: String) -> [UInt8] {
    var address = in6_addr()
    guard inet_pton(AF_INET6, host, &address) == 1 else { return [] }
    return withUnsafeBytes(of: address) { Array($0) }
  }
}
