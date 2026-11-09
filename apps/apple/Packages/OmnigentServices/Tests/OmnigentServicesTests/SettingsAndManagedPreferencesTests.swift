import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentServices

@Suite(.serialized) struct UserDefaultsSettingsStorageTests {
  /// Runs `body` against a fresh defaults suite, removed afterwards.
  private func withDefaults(_ body: (UserDefaults, UserDefaultsSettingsStorage) throws -> Void)
    throws
  {
    let suite = "ai.omnigent.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults, UserDefaultsSettingsStorage(defaults: defaults))
  }

  @Test(
    "A number JSON can't hold is reported instead of crashing the read",
    arguments: [Double.nan, Double.infinity, -Double.infinity])
  func nonFiniteSetting(number: Double) throws {
    try withDefaults { defaults, storage in
      defaults.set(number, forKey: "omnigent.number")
      defaults.set([number], forKey: "omnigent.numbers")
      #expect(throws: SettingsStorageError.self) { try storage.get(key: "omnigent.number") }
      #expect(throws: SettingsStorageError.self) { try storage.get(key: "omnigent.numbers") }
    }
  }

  /// A string can hold half of a surrogate pair, which has no UTF-8 and so no JSON form.
  @Test func aStringWithNoUTF8FormIsReportedInsteadOfCrashingTheRead() throws {
    try withDefaults { defaults, storage in
      defaults.register(defaults: ["omnigent.broken": loneSurrogateString()])
      guard
        case .Failed(let message) = thrownError({ _ = try storage.get(key: "omnigent.broken") })
          as? SettingsStorageError
      else {
        Issue.record("expected the read to fail")
        return
      }
      #expect(message.contains("could not be encoded as JSON"))
    }
  }

  @Test func storesStringsNativelyForAppStorageCompatibility() throws {
    try withDefaults { defaults, storage in
      try storage.set(key: "omnigent.serverURL", value: "\"https://example.com\"")
      #expect(defaults.string(forKey: "omnigent.serverURL") == "https://example.com")
      let observed1 = try storage.get(key: "omnigent.serverURL")
      #expect(observed1 == "\"https://example.com\"")
    }
  }

  @Test func readsStringsWrittenByAppStorage() throws {
    try withDefaults { defaults, storage in
      defaults.set("https://native.example", forKey: "omnigent.serverURL")
      let observed2 = try storage.get(key: "omnigent.serverURL")
      #expect(observed2 == "\"https://native.example\"")
    }
  }

  @Test func roundTripsObjectsBooleansAndNumbers() throws {
    try withDefaults { _, storage in
      try storage.set(key: "flags", value: "{\"a\":[1,true,\"x\"]}")
      let observed3 = try storage.get(key: "flags")
      #expect(observed3 == "{\"a\":[1,true,\"x\"]}")
      try storage.set(key: "count", value: "42")
      let observed4 = try storage.get(key: "count")
      #expect(observed4 == "42")
      try storage.set(key: "enabled", value: "true")
      let observed5 = try storage.get(key: "enabled")
      #expect(observed5 == "true")
    }
  }

  @Test func nilAndJSONNullRemoveTheKey() throws {
    try withDefaults { defaults, storage in
      try storage.set(key: "k", value: "\"v\"")
      try storage.set(key: "k", value: nil)
      let observed6 = try storage.get(key: "k")
      #expect(observed6 == nil)
      #expect(defaults.object(forKey: "k") == nil)

      try storage.set(key: "k", value: "\"again\"")
      try storage.set(key: "k", value: "null")
      let observed7 = try storage.get(key: "k")
      #expect(observed7 == nil)
    }
  }

  @Test func rejectsInvalidJSON() throws {
    try withDefaults { _, storage in
      let error = thrownError { try storage.set(key: "k", value: "{not json") }
      #expect(error is SettingsStorageError)
    }
  }

  @Test func rejectsNullInsideAContainer() throws {
    try withDefaults { _, storage in
      let error = thrownError { try storage.set(key: "k", value: "[1, null]") }
      #expect(error is SettingsStorageError)
    }
  }

  @Test func reportsValuesWithoutAJSONFormInsteadOfCrashing() throws {
    try withDefaults { defaults, storage in
      defaults.set(Date(timeIntervalSince1970: 0), forKey: "date")
      defaults.set(Data([1, 2, 3]), forKey: "data")
      let dateError = thrownError { _ = try storage.get(key: "date") }
      let dataError = thrownError { _ = try storage.get(key: "data") }
      #expect(dateError is SettingsStorageError)
      #expect(dataError is SettingsStorageError)
    }
  }
}

@Suite struct ManagedPreferencesSourceTests {
  private let domain = "ai.omnigent.mac"

  private func source(
    _ values: [String: any Sendable], forced: Set<String> = []
  ) -> ManagedPreferencesSource {
    let read: @Sendable (String, String) -> Any? = { key, domain in
      guard domain == "ai.omnigent.mac" else { return nil }
      return values[key]
    }
    let isForced: @Sendable (String, String) -> Bool = { key, domain in
      domain == "ai.omnigent.mac" && forced.contains(key)
    }
    return ManagedPreferencesSource(reader: read, forced: isForced)
  }

  @Test func convertsPropertyListValuesToJSONText() {
    let managed = source([
      "serverUrls": ["https://a.example", "https://b.example"],
      "enabled": true,
      "count": 1,
      "name": "Omnigent",
      "when": Date(timeIntervalSince1970: 0),
      "blob": Data([1, 2, 3]),
    ])

    #expect(
      managed.value(key: "serverUrls", domain: domain)
        == "[\"https://a.example\",\"https://b.example\"]")
    #expect(managed.value(key: "name", domain: domain) == "\"Omnigent\"")
    #expect(managed.value(key: "when", domain: domain) == "\"1970-01-01T00:00:00Z\"")
    #expect(managed.value(key: "blob", domain: domain) == "\"AQID\"")
  }

  @Test func keepsBooleansDistinctFromNumbers() {
    let managed = source(["enabled": true, "count": 1, "zero": false])
    #expect(managed.value(key: "enabled", domain: domain) == "true")
    #expect(managed.value(key: "count", domain: domain) == "1")
    #expect(managed.value(key: "zero", domain: domain) == "false")
  }

  @Test func missingKeysAndOtherDomainsAreAbsent() {
    let managed = source(["name": "x"])
    #expect(managed.value(key: "missing", domain: domain) == nil)
    #expect(managed.value(key: "name", domain: "ai.omnigent.other") == nil)
  }

  @Test func unexpectedTypesAreAbsentWithoutCrashing() {
    let managed = source(["url": URL(string: "https://example.com")!])
    #expect(managed.value(key: "url", domain: domain) == nil)
  }

  @Test func reportsForcedKeysFromTheInjectedSource() {
    let managed = source(["serverUrls": ["https://a.example"]], forced: ["serverUrls"])
    #expect(managed.isForced(key: "serverUrls", domain: domain))
    #expect(!managed.isForced(key: "other", domain: domain))
  }

  @Test func aManagedStringWithNoUTF8FormIsRefused() {
    let error = thrownError {
      _ = try ManagedPreferencesSource.jsonText(for: loneSurrogateString())
    }
    guard case .unsupportedType(let detail) = error as? ManagedPreferenceError else {
      Issue.record("expected the conversion to fail")
      return
    }
    #expect(detail.contains("UTF8"))
  }

  @Test func jsonTextRejectsNonFiniteNumbers() {
    do {
      _ = try ManagedPreferencesSource.jsonText(for: Double.nan)
      Issue.record("NaN should not convert")
    } catch {
      #expect(error == .nonFiniteNumber)
    }
  }
}
