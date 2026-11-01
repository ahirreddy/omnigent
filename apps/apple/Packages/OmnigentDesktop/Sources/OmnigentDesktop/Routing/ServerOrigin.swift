public import Foundation

/// Why a scheme, host or port does not form a usable server origin.
nonisolated public enum ServerOriginError: Error, Equatable, Sendable {
  /// The scheme is not `http` or `https`.
  case unsupportedScheme(String)
  /// The host is empty.
  case missingHost
  /// The host contains characters outside a DNS name, IPv4 address or bracketed IPv6 literal.
  case invalidHost(String)
  /// The port is not a decimal number from 0 to 65535.
  case invalidPort(String)
  /// The origin includes a user name or password.
  case credentialsNotAllowed
}

/// An http(s) origin: scheme, lowercased host and non-default port, as in WHATWG `URL.origin`.
///
/// Windows, deep links, notifications and managed preferences compare servers by origin, so two
/// spellings of one server (`HTTPS://Example.com:443` and `https://example.com`) are equal.
nonisolated public struct ServerOrigin: Hashable, Sendable, CustomStringConvertible {
  /// The origin scheme.
  public enum Scheme: String, Hashable, Sendable {
    /// Plain HTTP, used for loopback servers.
    case http
    /// TLS.
    case https

    /// The port that is omitted from a serialized origin.
    public var defaultPort: Int {
      switch self {
      case .http: 80
      case .https: 443
      }
    }
  }

  /// Hosts that run on this machine. They default to `http`, everything else to `https`.
  public static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]"]

  /// The scheme.
  public let scheme: Scheme
  /// Lowercased host; IPv6 literals keep their brackets, for example `[::1]`.
  public let host: String
  /// Explicit port, or `nil` when it is the scheme's default.
  public let port: Int?

  /// Validates and normalizes an origin.
  /// - Parameters:
  ///   - scheme: The scheme.
  ///   - host: A DNS name, dotted IPv4 address or bracketed IPv6 literal. Case is folded.
  ///   - port: The port; the scheme's default port is dropped.
  /// - Throws: `ServerOriginError` when the host or port is invalid.
  public init(scheme: Scheme, host: String, port: Int? = nil) throws(ServerOriginError) {
    self.scheme = scheme
    self.host = try OriginGrammar.normalizedHost(host)
    if let port {
      guard (0...65_535).contains(port) else { throw .invalidPort(String(port)) }
      self.port = port == scheme.defaultPort ? nil : port
    } else {
      self.port = nil
    }
  }

  /// The origin of an absolute http(s) URL. Paths, queries and fragments are ignored.
  /// - Parameter url: An `http` or `https` URL.
  /// - Throws: `ServerOriginError` for other schemes, credentials or an invalid host.
  public init(url: URL) throws(ServerOriginError) {
    let rawScheme = url.scheme?.lowercased() ?? ""
    guard let scheme = Scheme(rawValue: rawScheme) else { throw .unsupportedScheme(rawScheme) }
    guard url.user(percentEncoded: true) == nil, url.password(percentEncoded: true) == nil else {
      throw .credentialsNotAllowed
    }
    guard var host = url.host(percentEncoded: true), !host.isEmpty else { throw .missingHost }
    if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
    try self.init(scheme: scheme, host: host, port: url.port)
  }

  /// Parses a serialized origin such as `https://example.com:8443`.
  /// - Parameter serialized: `scheme://host[:port]`, optionally with a trailing `/`.
  /// - Throws: `ServerOriginError` when it is not a bare http(s) origin.
  public init(serialized: String) throws(ServerOriginError) {
    guard let separator = serialized.range(of: "://") else {
      throw .unsupportedScheme(serialized)
    }
    let rawScheme = serialized[..<separator.lowerBound].lowercased()
    guard let scheme = Scheme(rawValue: rawScheme) else { throw .unsupportedScheme(rawScheme) }
    var authority = serialized[separator.upperBound...]
    if authority.hasSuffix("/") { authority = authority.dropLast() }
    let (host, port) = try OriginGrammar.splitAuthority(authority)
    try self.init(scheme: scheme, host: host, port: port)
  }

  /// Whether the host is this machine.
  public var isLoopback: Bool { Self.loopbackHosts.contains(host) }

  /// `host[:port]`, the form a deep link carries and a server label shows.
  public var authority: String {
    port.map { "\(host):\($0)" } ?? host
  }

  /// `scheme://host[:port]` with no trailing slash, matching WHATWG `URL.origin`.
  public var serialized: String { "\(scheme.rawValue)://\(authority)" }

  /// The origin as a URL with an empty path. `nil` only if Foundation rejects a validated host.
  public var url: URL? { URL(string: serialized) }

  /// The serialized origin.
  public var description: String { serialized }

  /// The scheme a schemeless `host[:port]` gets: `http` for loopback, otherwise `https`.
  /// - Parameter normalizedHost: A host already folded by `ServerOrigin.init`.
  /// - Returns: The inferred scheme.
  public static func inferredScheme(forHost normalizedHost: String) -> Scheme {
    loopbackHosts.contains(normalizedHost) ? .http : .https
  }
}

extension ServerOrigin: Codable {
  /// Decodes a serialized origin string.
  /// - Parameter decoder: The decoder.
  /// - Throws: `DecodingError.dataCorrupted` when the string is not a valid origin.
  nonisolated public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    do {
      try self.init(serialized: raw)
    } catch {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid server origin \(raw): \(error)")
    }
  }

  /// Encodes the serialized origin string.
  /// - Parameter encoder: The encoder.
  /// - Throws: Any encoder error.
  nonisolated public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(serialized)
  }
}

/// Host and port grammar shared by origins and deep links. Standard library only.
nonisolated enum OriginGrammar {
  /// Splits `host[:port]`. An empty port (`host:`) means the default, as in WHATWG URL.
  static func splitAuthority(_ authority: Substring) throws(ServerOriginError) -> (String, Int?) {
    guard !authority.isEmpty else { throw .missingHost }
    guard !authority.contains("@") else { throw .credentialsNotAllowed }
    let host: Substring
    let portText: Substring?
    if authority.hasPrefix("[") {
      guard let close = authority.firstIndex(of: "]") else {
        throw .invalidHost(String(authority))
      }
      host = authority[...close]
      let rest = authority[authority.index(after: close)...]
      if rest.isEmpty {
        portText = nil
      } else if rest.hasPrefix(":") {
        portText = rest.dropFirst()
      } else {
        throw .invalidHost(String(authority))
      }
    } else if let colon = authority.firstIndex(of: ":") {
      host = authority[..<colon]
      portText = authority[authority.index(after: colon)...]
    } else {
      host = authority
      portText = nil
    }
    return (String(host), try parsePort(portText))
  }

  static func parsePort(_ text: Substring?) throws(ServerOriginError) -> Int? {
    guard let text, !text.isEmpty else { return nil }
    guard text.count <= 5, text.allSatisfy(\.isASCIIDigit), let value = Int(text),
      value <= 65_535
    else { throw .invalidPort(String(text)) }
    return value
  }

  static func normalizedHost(_ raw: String) throws(ServerOriginError) -> String {
    guard !raw.isEmpty else { throw .missingHost }
    // Non-ASCII is rejected before case folding: `lowercased()` maps some non-ASCII scalars
    // (KELVIN SIGN) to ASCII letters.
    guard raw.unicodeScalars.allSatisfy(\.isASCII) else { throw .invalidHost(raw) }
    let host = raw.lowercased()
    if host.hasPrefix("[") {
      let inner = host.dropFirst().dropLast()
      guard host.hasSuffix("]"), inner.contains(":"),
        inner.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." })
      else { throw .invalidHost(raw) }
      return host
    }
    guard host.allSatisfy({ $0.isASCIIHostCharacter }), !host.hasPrefix("."),
      !host.contains("..")
    else { throw .invalidHost(raw) }
    try rejectAmbiguousNumericHost(host, raw: raw)
    return host
  }

  /// WHATWG URL reinterprets a host whose last label is numeric (`0x7f000001`, `2130706433`,
  /// `1.2.3`) as an IPv4 address. Only canonical dotted quads are accepted so the host we compare
  /// is the host the network stack connects to.
  private static func rejectAmbiguousNumericHost(_ host: String, raw: String)
    throws(ServerOriginError)
  {
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    let trimmed = labels.last?.isEmpty == true ? labels.dropLast() : labels[...]
    guard let last = trimmed.last else { throw .invalidHost(raw) }
    let lastIsNumeric =
      last.allSatisfy(\.isASCIIDigit)
      || (last.lowercased().hasPrefix("0x") && last.dropFirst(2).allSatisfy(\.isHexDigit))
    guard lastIsNumeric else { return }
    guard trimmed.count == 4, labels.count == 4,
      trimmed.allSatisfy({ label in
        !label.isEmpty && label.count <= 3 && label.allSatisfy(\.isASCIIDigit)
          && (label == "0" || !label.hasPrefix("0")) && (Int(label) ?? 256) <= 255
      })
    else { throw .invalidHost(raw) }
  }
}

nonisolated extension Character {
  var isASCIIDigit: Bool { isASCII && isNumber }

  var isASCIIHostCharacter: Bool {
    guard isASCII, let scalar = unicodeScalars.first else { return false }
    switch scalar {
    case "a"..."z", "0"..."9", "-", ".", "_": return true
    default: return false
    }
  }
}
