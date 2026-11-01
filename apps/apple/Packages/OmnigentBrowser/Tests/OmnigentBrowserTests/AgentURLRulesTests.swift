import Foundation
import Testing

@testable import OmnigentBrowser

/// `BrowserURLRules` must decide exactly as the web host's `NavigationRules`
/// (WebHost/Sources/OWLNavigationRules.mm).
@Suite("URL rules")
struct AgentURLRulesTests {
  private func decide(_ rules: BrowserURLRules, _ url: String) throws -> BrowserURLDecision {
    rules.evaluate(try #require(URL(string: url)))
  }

  private func allowed(_ rules: BrowserURLRules, _ url: String) throws -> Bool {
    try decide(rules, url) == .allow
  }

  @Test func defaultsAllowPublicWebAndBlockEverythingElse() throws {
    let rules = BrowserURLRules()
    #expect(try allowed(rules, "https://example.com/path"))
    #expect(try allowed(rules, "http://93.184.216.34/"))
    #expect(try allowed(rules, "about:blank"))
    #expect(try !allowed(rules, "file:///etc/passwd"))
    #expect(try !allowed(rules, "javascript:alert(1)"))
    #expect(try !allowed(rules, "data:text/html,hi"))
    #expect(try !allowed(rules, "http://localhost:8080/"))
    #expect(try !allowed(rules, "http://app.localhost/"))
    #expect(try !allowed(rules, "http://127.0.0.1/"))
    #expect(try !allowed(rules, "http://[::1]/"))
    #expect(try !allowed(rules, "http://169.254.169.254/latest/meta-data"))
    #expect(try !allowed(rules, "http://10.1.2.3/"))
    #expect(try !allowed(rules, "http://172.20.0.1/"))
    #expect(try !allowed(rules, "http://192.168.1.1/"))
    #expect(try !allowed(rules, "http://100.64.0.1/"))
    #expect(try !allowed(rules, "http://[fd00::1]/"))
    #expect(try !allowed(rules, "http://[fe80::1]/"))
    #expect(try !allowed(rules, "http://[::ffff:10.0.0.1]/"))
    #expect(try allowed(rules, "http://[2606:4700::1111]/"))
    #expect(try !allowed(rules, "http://[2001:db8::1]/"))
  }

  @Test func reasonsNameTheRule() throws {
    let rules = BrowserURLRules(allow: ["example.com"], deny: ["bad.example.com"])
    #expect(try decide(rules, "ftp://example.com/") == .deny("The scheme \"ftp\" is not allowed."))
    #expect(
      try decide(rules, "https://bad.example.com/")
        == .deny("The host bad.example.com is on the deny list."))
    #expect(
      try decide(rules, "https://other.test/")
        == .deny("The host other.test is not on the allow list."))
  }

  @Test func patternsMatchTheHostAndItsSubdomains() throws {
    let rules = BrowserURLRules(allow: ["example.com", "*.docs.test", ".wiki.test"])
    #expect(try allowed(rules, "https://example.com/"))
    #expect(try allowed(rules, "https://www.example.com/"))
    #expect(try allowed(rules, "https://EXAMPLE.com/"))
    #expect(try !allowed(rules, "https://notexample.com/"))
    #expect(try !allowed(rules, "https://example.com.evil.test/"))
    #expect(try allowed(rules, "https://docs.test/"))
    #expect(try allowed(rules, "https://a.b.wiki.test/"))
    #expect(!BrowserURLRules.host("example.com", matches: ""))
  }

  @Test func denyWinsOverAllow() throws {
    let rules = BrowserURLRules(allow: ["example.com"], deny: ["admin.example.com"])
    #expect(try allowed(rules, "https://example.com/"))
    #expect(try !allowed(rules, "https://admin.example.com/"))
    #expect(try !allowed(rules, "https://x.admin.example.com/"))
  }

  @Test func loopbackNeedsAllowLoopback() throws {
    let loopback = BrowserURLRules(allow: ["example.com"], allowLoopback: true)
    #expect(try allowed(loopback, "http://localhost:3000/"))
    #expect(try allowed(loopback, "http://127.0.0.1/"))
    #expect(try !allowed(loopback, "http://10.0.0.1/"))
    #expect(try !allowed(loopback, "https://other.test/"))
    let open = BrowserURLRules(blockPrivateAddresses: false)
    #expect(try allowed(open, "http://localhost/"))
    #expect(try allowed(open, "http://192.168.0.1/"))
  }

  @Test func unrestrictedAllowsAnyScheme() throws {
    #expect(try allowed(.unrestricted, "file:///tmp/x.html"))
    #expect(try allowed(.unrestricted, "data:text/html,hi"))
    #expect(try allowed(.unrestricted, "http://127.0.0.1/"))
  }

  @Test func rulesRoundTripAsJSON() throws {
    let rules = BrowserURLRules(allow: ["a.test"], deny: ["b.test"], allowLoopback: true)
    let decoded = try JSONDecoder().decode(
      BrowserURLRules.self, from: try JSONEncoder().encode(rules))
    #expect(decoded == rules)
  }
}
