import Foundation
import Testing

@testable import OmnigentDesktop

// Cases ported from web/electron/test/managed_preferences.test.js. Electron "fails closed" by
// returning an empty list; the native reader throws so the app can show why the list was ignored.

@MainActor
private func reader(
  _ values: [String: [String: Any]], forced: Set<String> = [],
  domains: [String] = ManagedPreferences.defaultDomains
) -> (ManagedPreferences, () -> [String]) {
  var calls: [String] = []
  let preferences = ManagedPreferences(
    domains: domains,
    readValue: { key, domain in
      calls.append("\(domain):\(key)")
      return values[domain]?[key]
    },
    readForced: { key, domain in forced.contains("\(domain):\(key)") })
  return (preferences, { calls })
}

private func urls(_ servers: [ManagedServer]) -> [String] {
  servers.map(\.url.absoluteString)
}

@Suite("Managed preferences")
@MainActor
struct ManagedPreferencesTests {
  @Test("reads serverUrls and preserves workspace paths")
  func readsServers() throws {
    let (preferences, calls) = reader([
      "ai.omnigent.desktop": [
        "serverUrls": ["omnigent.example.com", "https://workspace.example.com/ml/omnigents?o=123"]
      ]
    ])
    let snapshot = try preferences.servers()
    #expect(
      urls(snapshot.servers) == [
        "https://omnigent.example.com/", "https://workspace.example.com/ml/omnigents?o=123",
      ])
    #expect(snapshot.serversDomain == "ai.omnigent.desktop")
    #expect(snapshot.serversAreForced == false)
    #expect(calls() == ["ai.omnigent.mac:serverUrls", "ai.omnigent.desktop:serverUrls"])
  }

  @Test("a value that no profile enforces isn't read as forced")
  func notForcedByDefault() throws {
    let preferences = ManagedPreferences(
      domains: ["ai.omnigent.tests.not-a-real-domain"],
      readValue: { _, _ in ["https://acme.example.com"] })
    let snapshot = try preferences.servers()
    #expect(snapshot.servers.count == 1)
    #expect(!snapshot.serversAreForced)
  }

  @Test("returns nothing when no domain sets the key")
  func unset() throws {
    let snapshot = try reader([:]).0.servers()
    #expect(snapshot.servers.isEmpty)
    #expect(snapshot.serversDomain == nil)
  }

  @Test("the first domain that sets the key wins and values are not merged")
  func precedence() throws {
    let (preferences, _) = reader(
      [
        "ai.omnigent.mac": ["serverUrls": ["https://mac.example.com"]],
        "ai.omnigent.desktop": ["serverUrls": ["https://desktop.example.com"]],
      ], forced: ["ai.omnigent.mac:serverUrls"])
    let snapshot = try preferences.servers()
    #expect(urls(snapshot.servers) == ["https://mac.example.com/"])
    #expect(snapshot.serversDomain == "ai.omnigent.mac")
    #expect(snapshot.serversAreForced)
  }

  @Test("an invalid first domain is reported rather than skipped")
  func invalidFirstDomain() {
    let (preferences, _) = reader([
      "ai.omnigent.mac": ["serverUrls": "https://mac.example.com"],
      "ai.omnigent.desktop": ["serverUrls": ["https://desktop.example.com"]],
    ])
    #expect(throws: ManagedPreferencesError.notAnArray(domain: "ai.omnigent.mac")) {
      try preferences.servers()
    }
  }

  @Test("deduplicates by origin, keeping the first URL")
  func deduplicates() throws {
    let servers = try ManagedPreferences.parseServers(
      [
        "https://workspace.example.com/ml/omnigents",
        "https://workspace.example.com/another-mount",
        "https://other.example.com",
        "HTTPS://Other.Example.com:443/x",
      ], domain: "d")
    #expect(
      urls(servers) == ["https://workspace.example.com/ml/omnigents", "https://other.example.com/"])
  }

  @Test("rejects an invalid configuration as a whole")
  func rejectsWhole() {
    #expect(throws: ManagedPreferencesError.notAnArray(domain: "d")) {
      try ManagedPreferences.parseServers("https://omnigent.example.com", domain: "d")
    }
    #expect(
      throws: ManagedPreferencesError.invalidServer(
        domain: "d", index: 1, reason: "must use https://")
    ) {
      try ManagedPreferences.parseServers(
        ["https://valid.example.com", "http://insecure.example.com"], domain: "d")
    }
    let tooMany = (0...ManagedPreferences.maximumServerCount).map { "host\($0).com" }
    #expect(throws: ManagedPreferencesError.tooManyServers(domain: "d", count: 11)) {
      try ManagedPreferences.parseServers(tooMany, domain: "d")
    }
    #expect(
      throws: ManagedPreferencesError.invalidServer(
        domain: "d", index: 0, reason: "is not a string")
    ) {
      try ManagedPreferences.parseServers([42], domain: "d")
    }
    #expect(
      throws: ManagedPreferencesError.invalidServer(domain: "d", index: 0, reason: "is empty")
    ) {
      try ManagedPreferences.parseServers(["   "], domain: "d")
    }
  }

  @Test(
    "rejects credentials, bad hosts and bad ports",
    arguments: [
      "https://user:pass@example.com", "https://exa mple.com", "https://example.com:99999",
      "ftp://example.com", "https://",
    ])
  func rejectsEntries(_ entry: String) {
    #expect(throws: ManagedServerEntryError.self) { try ManagedPreferences.parseServer(entry) }
  }

  @Test("reads display names from omnigentServerName and strips the parameter")
  func displayNames() throws {
    let servers = try ManagedPreferences.parseServers(
      [
        "https://workspace.example.com/?o=123&omnigentServerName=%20Team%20A%20",
        "https://other.example.com/ml?omnigentServerName=",
        "plain.example.com",
        "https://plus.example.com/?omnigentServerName=Team+B&x=a%2Bb",
      ], domain: "d")
    #expect(
      urls(servers) == [
        "https://workspace.example.com/?o=123", "https://other.example.com/ml",
        "https://plain.example.com/", "https://plus.example.com/?x=a%2Bb",
      ])
    #expect(servers.map(\.name) == ["Team A", nil, nil, "Team B"])
    #expect(
      servers.map(\.displayName) == ["Team A", "other.example.com", "plain.example.com", "Team B"])
  }

  @Test("names only the servers the list keeps")
  func namesOnlyKept() throws {
    let servers = try ManagedPreferences.parseServers(
      ["https://team.example.com/", "https://team.example.com/other?omnigentServerName=Dropped"],
      domain: "d")
    #expect(servers.map(\.name) == [nil])
    #expect(throws: ManagedPreferencesError.self) {
      try ManagedPreferences.parseServers(
        ["https://team.example.com/?omnigentServerName=Team", "http://bad"], domain: "d")
    }
  }

  @Test("filters recents already represented by a managed origin")
  func excludesManaged() throws {
    let managed = try ManagedPreferences.parseServers(
      ["https://workspace.example.com/ml/omnigents"], domain: "d")
    let recents = try [
      url("https://workspace.example.com/old-mount"), url("https://personal.example.com/"),
      url("hand-edited-invalid-value"),
    ]
    #expect(
      ManagedPreferences.excludingManaged(recents, managed: managed).map(\.absoluteString) == [
        "https://personal.example.com/", "hand-edited-invalid-value",
      ])
  }

  @Test("internal features need an explicit boolean true")
  func internalFeatures() throws {
    let key = ManagedPreferences.databricksInternalFeaturesKey
    #expect(try reader(["ai.omnigent.desktop": [key: true]]).0.databricksInternalFeaturesEnabled())
    #expect(try !reader(["ai.omnigent.mac": [key: false]]).0.databricksInternalFeaturesEnabled())
    #expect(try !reader([:]).0.databricksInternalFeaturesEnabled())
    for value: Any in [1, "true", [true]] {
      #expect(throws: ManagedPreferencesError.notABoolean(domain: "ai.omnigent.mac", key: key)) {
        try reader(["ai.omnigent.mac": [key: value]]).0.databricksInternalFeaturesEnabled()
      }
    }
  }

  @Test("the app's own domain is read first, without duplicates")
  func domains() {
    #expect(
      ManagedPreferences.domains(forBundleIdentifier: "ai.omnigent.mac.lab") == [
        "ai.omnigent.mac.lab", "ai.omnigent.mac", "ai.omnigent.desktop",
      ])
    #expect(
      ManagedPreferences.domains(forBundleIdentifier: "ai.omnigent.mac") == [
        "ai.omnigent.mac", "ai.omnigent.desktop",
      ])
    #expect(
      ManagedPreferences.domains(forBundleIdentifier: nil) == ManagedPreferences.defaultDomains)
  }

  @Test("sandboxed builds read only their own domain")
  func ownDomainOnly() {
    #expect(
      ManagedPreferences.domains(
        forBundleIdentifier: "ai.omnigent.mac.appstore", ownDomainOnly: true) == [
          "ai.omnigent.mac.appstore"
        ])
    #expect(ManagedPreferences.domains(forBundleIdentifier: nil, ownDomainOnly: true).isEmpty)
    #expect(ManagedPreferences(domains: ["a", "b"]).domains == ["a", "b"])
  }

  @Test("the default reader returns nothing for an unused domain")
  func realDefaults() throws {
    let preferences = ManagedPreferences(domains: ["ai.omnigent.tests.\(UUID().uuidString)"])
    #expect(try preferences.servers().servers.isEmpty)
    #expect(try !preferences.databricksInternalFeaturesEnabled())
  }
}
