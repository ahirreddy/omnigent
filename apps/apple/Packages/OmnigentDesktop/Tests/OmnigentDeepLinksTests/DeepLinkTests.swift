import Testing

@testable import OmnigentDeepLinks

// Cases ported from web/electron/test/deepLink.test.js ("parseOmnigentDeepLink" and "CLI
// navigation acknowledgment"), plus native-only hardening.

private func parse(_ raw: String) throws(DeepLinkError) -> OmnigentDeepLink {
  try OmnigentDeepLink(parsing: raw)
}

@Suite("Deep link parsing")
struct DeepLinkTests {
  @Test("parses a loopback host with a port as http")
  func loopbackIsHTTP() throws {
    let link = try parse("omnigent://localhost:8000/c/conv_abc")
    #expect(link.origin.serialized == "http://localhost:8000")
    #expect(link.route == .conversation(sessionID: "conv_abc"))
    #expect(link.route.path == "/c/conv_abc")
    #expect(try parse("omnigent://127.0.0.1:8000/c/x").origin.serialized == "http://127.0.0.1:8000")
  }

  @Test("parses a remote host as https")
  func remoteIsHTTPS() throws {
    let link = try parse("omnigent://my-workspace.cloud.databricks.com/c/x")
    #expect(link.origin.serialized == "https://my-workspace.cloud.databricks.com")
    #expect(link.route == .conversation(sessionID: "x"))
  }

  @Test("preserves a non-default port on a remote host")
  func remotePort() throws {
    #expect(
      try parse("omnigent://example.com:8443/c/x").origin.serialized == "https://example.com:8443")
  }

  @Test("accepts an IPv6 loopback host as http")
  func ipv6Loopback() throws {
    let link = try parse("omnigent://[::1]:8000/c/x")
    #expect(link.origin.serialized == "http://[::1]:8000")
    #expect(link.origin.isLoopback)
  }

  @Test("accepts an optional trailing slash on the path")
  func trailingSlash() throws {
    #expect(
      try parse("omnigent://localhost:8000/c/conv_abc/").route
        == .conversation(sessionID: "conv_abc"))
  }

  @Test("drops a query string and hash")
  func dropsQueryAndHash() throws {
    let link = try parse("omnigent://localhost:8000/c/conv_abc?reply=1#frag")
    #expect(link.route == .conversation(sessionID: "conv_abc"))
    #expect(link.origin.serialized == "http://localhost:8000")
    #expect(link.acknowledgment == nil)
  }

  @Test(
    "rejects a non-omnigent scheme",
    arguments: ["https://localhost:8000/c/x", "vscode://localhost/c/x"])
  func rejectsOtherSchemes(_ raw: String) {
    #expect(throws: DeepLinkError.unsupportedScheme) { try parse(raw) }
  }

  @Test(
    "rejects a link with no host", arguments: ["omnigent://", "omnigent:///c/x", "omnigent:c/x"])
  func rejectsMissingHost(_ raw: String) {
    #expect(throws: DeepLinkError.missingHost) { try parse(raw) }
  }

  @Test(
    "accepts the server-home root path",
    arguments: ["omnigent://localhost:8000/", "omnigent://localhost:8000"])
  func homeRoute(_ raw: String) throws {
    let link = try parse(raw)
    #expect(link.origin.serialized == "http://localhost:8000")
    #expect(link.route == .home)
    #expect(link.route.path == "/")
  }

  @Test(
    "rejects paths that are not a conversation, page or settings",
    arguments: [
      "omnigent://localhost:8000/members", "omnigent://localhost:8000/tasks/t_1",
      "omnigent://localhost:8000/settings/..", "omnigent://localhost:8000/settings/a/b/c",
      "omnigent://localhost:8000/c/", "omnigent://localhost:8000/c/a/b",
      "omnigent://localhost:8000//",
    ])
  func rejectsOtherPaths(_ raw: String) {
    #expect {
      try parse(raw)
    } throws: { error in
      guard case .unsupportedPath = error as? DeepLinkError else { return false }
      return true
    }
  }

  @Test("opens the web app's pages and settings sections")
  func pagesAndSettings() throws {
    #expect(try parse("omnigent://127.0.0.1:6767/usage").route == .page(.usage))
    #expect(try parse("omnigent://127.0.0.1:6767/new/").route == .page(.newSession))
    #expect(try parse("omnigent://127.0.0.1:6767/tasks").route == .page(.automations))
    #expect(try parse("omnigent://127.0.0.1:6767/inbox").route.path == "/inbox")
    #expect(try parse("omnigent://127.0.0.1:6767/settings").route == .settings(section: nil))
    let section = try parse("omnigent://127.0.0.1:6767/settings/custom-agents").route
    #expect(section == .settings(section: "custom-agents"))
    #expect(section.path == "/settings/custom-agents")
    #expect(
      try parse("omnigent://127.0.0.1:6767/settings/harnesses/codex").route
        == .settings(section: "harnesses"))
  }

  @Test("rejects unparseable input")
  func rejectsGarbage() {
    #expect(throws: DeepLinkError.invalidCharacters) { try parse("not a url") }
    #expect(throws: DeepLinkError.unsupportedScheme) { try parse("") }
    #expect(throws: DeepLinkError.unsupportedScheme) { try parse("123") }
    #expect(throws: DeepLinkError.invalidCharacters) { try parse("omnigent://local host/c/x") }
  }

  @Test("folds scheme and host case and drops the default port")
  func normalization() throws {
    let link = try parse("  OMNIGENT://Example.COM:443/c/x\n")
    #expect(link.origin.serialized == "https://example.com")
    #expect(try parse("omnigent://LOCALHOST/c/x").origin.serialized == "http://localhost")
    #expect(try parse("omnigent://localhost:80/").origin.serialized == "http://localhost")
    #expect(try parse("omnigent://localhost:/").origin.serialized == "http://localhost")
  }

  @Test("infers https for non-loopback IP literals")
  func nonLoopbackLiterals() throws {
    #expect(try parse("omnigent://10.0.0.5:8000/c/x").origin.serialized == "https://10.0.0.5:8000")
    #expect(try parse("omnigent://[fe80::1]/c/x").origin.serialized == "https://[fe80::1]")
  }

  @Test("percent-decodes the session id")
  func decodesSessionID() throws {
    #expect(
      try parse("omnigent://localhost/c/conv%5Fabc").route == .conversation(sessionID: "conv_abc"))
    #expect {
      try parse("omnigent://localhost/c/a%2Fb")
    } throws: { error in
      guard case .unsupportedPath = error as? DeepLinkError else { return false }
      return true
    }
  }

  @Test(
    "rejects credentials and ambiguous hosts",
    arguments: [
      (
        "omnigent://trusted.example.com@evil.example.com/c/x",
        ServerOriginError.credentialsNotAllowed
      ),
      ("omnigent://0x7f000001/c/x", .invalidHost("0x7f000001")),
      ("omnigent://2130706433/c/x", .invalidHost("2130706433")),
      ("omnigent://1.2.3/c/x", .invalidHost("1.2.3")),
      ("omnigent://127.0.0.01/c/x", .invalidHost("127.0.0.01")),
      ("omnigent://exa%6Dple.com/c/x", .invalidHost("exa%6Dple.com")),
      ("omnigent://caf\u{E9}.example/c/x", .invalidHost("caf\u{E9}.example")),
      ("omnigent://[::1/c/x", .invalidHost("[::1")),
      ("omnigent://localhost:99999/c/x", .invalidPort("99999")),
      ("omnigent://localhost:80a/c/x", .invalidPort("80a")),
    ])
  func rejectsInvalidOrigins(_ raw: String, _ expected: ServerOriginError) {
    #expect(throws: DeepLinkError.invalidOrigin(expected)) { try parse(raw) }
  }
}

@Suite("CLI navigation acknowledgment")
struct DeepLinkAcknowledgmentTests {
  static let token = String(repeating: "a", count: 64)

  @Test("ordinary links carry no acknowledgment")
  func ordinaryLink() throws {
    #expect(try parse("omnigent://localhost:6767/").acknowledgment == nil)
  }

  @Test("parses a well-formed acknowledgment")
  func parsesAcknowledgment() throws {
    let link = try parse("omnigent://localhost/?desktop_ack=1234:\(Self.token)")
    #expect(link.acknowledgment == DeepLinkAcknowledgment(port: 1234, nonce: Self.token))
    #expect(link.acknowledgment?.callbackPath == "/desktop-open/\(Self.token)")
    #expect(
      try parse("omnigent://localhost/?desktop_ack=1234%3A\(Self.token)").acknowledgment?.port
        == 1234)
  }

  @Test(
    "rejects malformed callbacks",
    arguments: [
      "", "0:\(token)", "65536:\(token)", "123:bad", "https://example.com",
      "1234:\(token.uppercased())",
    ])
  func rejectsMalformed(_ acknowledgment: String) {
    #expect {
      try parse("omnigent://localhost/?desktop_ack=\(acknowledgment)")
    } throws: { error in
      guard case .invalidAcknowledgment = error as? DeepLinkError else { return false }
      return true
    }
  }

  @Test("rejects duplicate callbacks and unsupported routes")
  func rejectsDuplicatesAndRoutes() {
    #expect(throws: DeepLinkError.invalidAcknowledgment("duplicate desktop_ack")) {
      try parse("omnigent://localhost/?desktop_ack=123:\(Self.token)&desktop_ack=123:\(Self.token)")
    }
    #expect(throws: DeepLinkError.unsupportedPath("/members")) {
      try parse("omnigent://localhost/members?desktop_ack=123:\(Self.token)")
    }
  }

  @Test("an invite opens before sign-in; one without a token is rejected")
  func invites() throws {
    let link = try parse("omnigent://omni.example.com/register?invite=a%2Bb_1&x=y")
    #expect(link.route == .register(invite: "a+b_1"))
    #expect(link.route.appliesBeforeSignIn)
    #expect(!DeepLinkRoute.home.appliesBeforeSignIn)
    #expect(
      try parse("omnigent://omni.example.com/register/?invite=t").route == .register(invite: "t"))
    #expect(throws: DeepLinkError.unsupportedPath("/register")) {
      try parse("omnigent://omni.example.com/register?invite=")
    }
    #expect(throws: DeepLinkError.unsupportedPath("/register")) {
      try parse("omnigent://omni.example.com/register")
    }
  }
}
