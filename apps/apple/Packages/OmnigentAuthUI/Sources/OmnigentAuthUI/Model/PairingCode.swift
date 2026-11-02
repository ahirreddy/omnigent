import Foundation

/// Why scanned or pasted text is not a pairing code this app accepts.
public nonisolated enum PairingCodeError: Error, Hashable, Sendable {
  /// Not an `omnigent:pair` code.
  case notAPairingCode
  /// A pairing code from a newer app.
  case unsupportedVersion
  /// No server in the code.
  case missingServer
  /// The core's URL rules reject the server; the message is the core's.
  case invalidServer(String)

  /// For display.
  public var message: String {
    switch self {
    case .notAPairingCode: "This isn't an Omnigent pairing code."
    case .unsupportedVersion: "This pairing code needs a newer version of Omnigent."
    case .missingServer: "This pairing code has no server address."
    case .invalidServer(let message): message
    }
  }
}

/// The QR code the Mac shows in Settings › Phone and the phone scans: the server's URL, so the
/// phone can connect and sign in on its own. It carries no credential.
///
/// The text is `omnigent:pair?v=1&server=<percent-encoded URL>`. It has no `//` authority, so the
/// `omnigent://` deep-link parsers reject it instead of reading `pair` as a host. Unknown query
/// items are ignored, so a later version can add a short-lived link token.
public nonisolated struct PairingCode: Hashable, Sendable {
  /// The scheme, shared with deep links so the system camera hands the code to the app.
  public static let scheme = "omnigent"
  /// The path that marks a pairing code.
  public static let path = "pair"
  /// The version this app writes and reads.
  public static let version = 1
  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  /// The server URL, as the Mac connects to it.
  public var serverURL: String

  /// Creates a code for `serverURL`.
  /// - Parameter serverURL: The server's canonical URL.
  public init(serverURL: String) {
    self.serverURL = serverURL
  }

  /// The text the QR code encodes.
  public var text: String {
    let server = serverURL.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
    return "\(Self.scheme):\(Self.path)?v=\(Self.version)&server=\(server)"
  }

  /// Reads scanned or pasted text.
  /// - Parameter raw: The text.
  /// - Throws: ``PairingCodeError`` for anything but a v1 code with a server.
  public init(parsing raw: String) throws(PairingCodeError) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: trimmed),
      components.scheme?.lowercased() == Self.scheme, components.host == nil,
      components.path == Self.path
    else { throw .notAPairingCode }
    let items = components.queryItems ?? []
    guard items.first(where: { $0.name == "v" })?.value == String(Self.version) else {
      throw .unsupportedVersion
    }
    guard let server = items.first(where: { $0.name == "server" })?.value,
      !server.trimmingCharacters(in: .whitespaces).isEmpty
    else { throw .missingServer }
    self.init(serverURL: server)
  }

  /// Checks the server with the core's rules, for the confirmation the phone shows before it
  /// connects. A code is never trusted on its own: the user sees the host and confirms.
  /// - Parameter validator: The core's URL check.
  /// - Returns: What to confirm.
  /// - Throws: ``PairingCodeError/invalidServer(_:)``.
  public func confirmation(validator: ServerURLValidator) throws(PairingCodeError)
    -> PairingConfirmation
  {
    switch validator.check(serverURL) {
    case .valid(let normalized):
      return PairingConfirmation(
        serverURL: normalized, host: ServerIdentity.hostLabel(normalized),
        isLoopback: Self.isLoopback(normalized))
    case .invalid(let message):
      throw .invalidServer(message)
    case .empty:
      throw .missingServer
    }
  }

  /// Whether `url` names this device (`localhost`, `127.0.0.1`, `[::1]`), which another device
  /// can't reach.
  /// - Parameter url: A server URL.
  /// - Returns: Whether it is loopback.
  public static func isLoopback(_ url: String) -> Bool {
    guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
    return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
  }
}

/// A validated pairing code, ready to confirm.
public nonisolated struct PairingConfirmation: Hashable, Sendable, Identifiable {
  /// The normalized URL connecting will use.
  public var serverURL: String
  /// `host[:port]`, shown prominently.
  public var host: String
  /// The server is loopback on the device that showed the code.
  public var isLoopback: Bool

  /// The URL.
  public var id: String { serverURL }
}
