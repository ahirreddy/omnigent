// Pure `omnigent://` parsing, ported from web/electron/src/deepLink.js. Standard library only so
// it can move to the Rust core unchanged; covered by DeepLinkTests.

/// Why a string is not an `omnigent://` link the desktop app handles.
nonisolated public enum DeepLinkError: Error, Equatable, Sendable {
  /// The scheme is missing or is not `omnigent`.
  case unsupportedScheme
  /// There is no `//host` authority (`omnigent:` or `omnigent:///c/x`).
  case missingHost
  /// The host or port is invalid.
  case invalidOrigin(ServerOriginError)
  /// The path is neither `/` nor `/c/<session>`.
  case unsupportedPath(String)
  /// The link contains whitespace or control characters.
  case invalidCharacters
  /// `desktop_ack` is repeated or is not `<port>:<64 hex>`.
  case invalidAcknowledgment(String)
}

/// Where inside a server a deep link points.
nonisolated public enum DeepLinkRoute: Hashable, Sendable {
  /// The server home, `omnigent://host` or `omnigent://host/`.
  case home
  /// A conversation, `omnigent://host/c/<sessionID>`.
  case conversation(sessionID: String)
  /// A message in a conversation, `omnigent://host/c/<sessionID>?message=<messageID>` (the web's
  /// Copy link): a user message by its item id, an answer by its response id.
  case message(sessionID: String, messageID: String)
  /// An invite, `omnigent://host/register?invite=<token>`: Create Account with it.
  case register(invite: String)

  /// The basename-less SPA path for this route, `/`, `/c/<id>` or `/register`.
  public var path: String {
    switch self {
    case .home: "/"
    case .conversation(let sessionID), .message(let sessionID, _): "/c/\(sessionID)"
    case .register: "/register"
    }
  }

  /// The session the route shows, if any.
  public var sessionID: String? {
    switch self {
    case .conversation(let sessionID), .message(let sessionID, _): sessionID
    case .home, .register: nil
    }
  }

  /// Whether a window opens the route while still signing in, as an invite must.
  public var appliesBeforeSignIn: Bool {
    if case .register = self { return true }
    return false
  }
}

/// A one-time CLI handshake: `omnigent start --open-in-desktop` waits for
/// `POST http://127.0.0.1:<port>/desktop-open/<nonce>` before deciding not to open a browser.
nonisolated public struct DeepLinkAcknowledgment: Hashable, Sendable {
  /// IPv4 loopback port the CLI listens on, 1 to 65535.
  public let port: Int
  /// 64 lowercase hex characters.
  public let nonce: String

  /// The callback the desktop POSTs to. Always loopback, never a URL supplied by the link.
  public var callbackPath: String { "/desktop-open/\(nonce)" }
}

/// A parsed `omnigent://<host>[:port]/c/<session>[?message=<id>]` link.
///
/// The link names a server by host and carries no http/https. The scheme is inferred the way the
/// connect screen does: `http` for loopback, `https` for anything else. Workspace mounts such as
/// `/omnigent` are not part of the link; they are discovered from the server.
nonisolated public struct OmnigentDeepLink: Hashable, Sendable {
  /// The URL scheme the app registers in `CFBundleURLTypes`.
  public static let scheme = "omnigent"

  /// The server origin with its inferred scheme.
  public let origin: ServerOrigin
  /// The in-app destination.
  public let route: DeepLinkRoute
  /// The CLI handshake, when the link came from `omnigent start --open-in-desktop`.
  public let acknowledgment: DeepLinkAcknowledgment?

  /// Parses a deep link. Queries other than `desktop_ack`, `message` and `invite`, and fragments,
  /// are ignored.
  /// - Parameter raw: For example `omnigent://localhost:8000/c/conv_abc`.
  /// - Throws: `DeepLinkError` describing the first problem found.
  public init(parsing raw: String) throws(DeepLinkError) {
    let trimmed = raw.trimmingASCIIWhitespace()
    guard trimmed.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F }) else {
      throw .invalidCharacters
    }
    guard let colon = trimmed.firstIndex(of: ":"),
      trimmed[..<colon].lowercased() == Self.scheme
    else { throw .unsupportedScheme }
    let afterScheme = trimmed[trimmed.index(after: colon)...]
    guard afterScheme.hasPrefix("//") else { throw .missingHost }
    let afterSlashes = afterScheme.dropFirst(2)

    let authorityEnd = afterSlashes.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" }
    let authority = afterSlashes[..<(authorityEnd ?? afterSlashes.endIndex)]
    guard !authority.isEmpty else { throw .missingHost }
    let rest = afterSlashes[(authorityEnd ?? afterSlashes.endIndex)...]

    let pathEnd = rest.firstIndex { $0 == "?" || $0 == "#" } ?? rest.endIndex
    let path = rest[..<pathEnd]
    var query: Substring = ""
    if rest[pathEnd...].hasPrefix("?") {
      let afterQuestion = rest[rest.index(after: pathEnd)...]
      query = afterQuestion[..<(afterQuestion.firstIndex(of: "#") ?? afterQuestion.endIndex)]
    }

    do {
      let (host, port) = try OriginGrammar.splitAuthority(authority)
      let normalizedHost = try OriginGrammar.normalizedHost(host)
      origin = try ServerOrigin(
        scheme: ServerOrigin.inferredScheme(forHost: normalizedHost), host: normalizedHost,
        port: port)
    } catch {
      throw .invalidOrigin(error)
    }
    route = try Self.route(path, query: query)
    acknowledgment = try Self.acknowledgment(query)
  }

  /// `""` and `/` are home; `/c/<id>` and `/c/<id>/` are a conversation, or one of its messages
  /// with a non-empty `message`; `/register` with a non-empty `invite` is an invite.
  private static func route(_ path: Substring, query: Substring) throws(DeepLinkError)
    -> DeepLinkRoute
  {
    if path.isEmpty || path == "/" { return .home }
    if path == "/register" || path == "/register/" {
      guard let invite = queryValue("invite", in: query), !invite.isEmpty else {
        throw .unsupportedPath(String(path))
      }
      return .register(invite: invite)
    }
    var segments = path.split(separator: "/", omittingEmptySubsequences: false)
    if segments.last?.isEmpty == true { segments.removeLast() }
    guard segments.count == 3, segments[0].isEmpty, segments[1] == "c", !segments[2].isEmpty,
      let sessionID = percentDecoded(segments[2]), !sessionID.isEmpty,
      !sessionID.contains("/"), sessionID.unicodeScalars.allSatisfy({ $0.value >= 0x20 })
    else { throw .unsupportedPath(String(path)) }
    if let messageID = queryValue("message", in: query), !messageID.isEmpty {
      return .message(sessionID: sessionID, messageID: messageID)
    }
    return .conversation(sessionID: sessionID)
  }

  private static func acknowledgment(_ query: Substring) throws(DeepLinkError)
    -> DeepLinkAcknowledgment?
  {
    var values: [String] = []
    for pair in query.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard let name = parts.first, formDecoded(name) == "desktop_ack" else { continue }
      guard let encoded = parts.dropFirst().first else {
        values.append("")
        continue
      }
      guard let value = formDecoded(encoded) else { throw .invalidAcknowledgment(String(encoded)) }
      values.append(value)
    }
    guard let value = values.first else { return nil }
    guard values.count == 1 else { throw .invalidAcknowledgment("duplicate desktop_ack") }
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let portText = parts.first, let nonce = parts.last,
      (1...5).contains(portText.count), portText.first != "0",
      portText.allSatisfy(\.isASCIIDigit), let port = Int(portText), port <= 65_535,
      nonce.count == 64,
      nonce.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
    else { throw .invalidAcknowledgment(value) }
    return DeepLinkAcknowledgment(port: port, nonce: String(nonce))
  }

  /// The first decoded value of `name` in `query`.
  private static func queryValue(_ name: String, in query: Substring) -> String? {
    for pair in query.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard let key = parts.first, formDecoded(key) == name else { continue }
      return parts.dropFirst().first.flatMap(formDecoded) ?? ""
    }
    return nil
  }

  /// `application/x-www-form-urlencoded` decoding, as URLSearchParams does.
  private static func formDecoded(_ text: Substring) -> String? {
    percentDecoded(Substring(text.replacing("+", with: " ")))
  }

  /// Percent-decodes UTF-8. A stray `%` is kept literally (WHATWG); invalid UTF-8 returns `nil`.
  private static func percentDecoded(_ text: Substring) -> String? {
    var bytes: [UInt8] = []
    var utf8 = text.utf8[...]
    while let byte = utf8.popFirst() {
      if byte == UInt8(ascii: "%"), utf8.count >= 2,
        let high = hexValue(utf8[utf8.startIndex]),
        let low = hexValue(utf8[utf8.index(after: utf8.startIndex)])
      {
        bytes.append(high << 4 | low)
        utf8 = utf8.dropFirst(2)
      } else {
        bytes.append(byte)
      }
    }
    return String(validating: bytes, as: UTF8.self)
  }

  private static func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
    default: nil
    }
  }
}

nonisolated extension StringProtocol {
  /// Strips leading and trailing C0 controls and spaces, as the WHATWG URL parser does.
  func trimmingASCIIWhitespace() -> Substring {
    let isTrimmed: (Character) -> Bool = { character in
      character.unicodeScalars.allSatisfy { $0.value <= 0x20 }
    }
    let string = Substring(self)
    guard let first = string.firstIndex(where: { !isTrimmed($0) }),
      let last = string.lastIndex(where: { !isTrimmed($0) })
    else { return "" }
    return string[first...last]
  }
}
