import Foundation
import Testing

@testable import OmnigentBrowser

@Suite("Profiles")
struct ProfileTests {
  @Test func storageKeysAreStableAndDistinct() {
    let alpha = BrowserProfile.server("alpha")
    #expect(alpha.storageKey == BrowserProfile.server("alpha").storageKey)
    #expect(alpha.storageKey != BrowserProfile.server("beta").storageKey)
    #expect(alpha.storageKey.count == 32)
    let isHex = alpha.storageKey.allSatisfy(\.isHexDigit)
    #expect(isHex)
  }

  @Test func dataStoreIdentifierIsDeterministicVersion8() {
    let id = BrowserProfile.server("alpha").dataStoreIdentifier
    #expect(id == BrowserProfile.server("alpha").dataStoreIdentifier)
    #expect(id != BrowserProfile.server("beta").dataStoreIdentifier)
    let text = id.uuidString
    let version = text[text.index(text.startIndex, offsetBy: 14)]
    #expect(version == "8")
  }
}

@Suite("Script values")
struct ScriptValueTests {
  @Test func foundationConversion() throws {
    #expect(try BrowserScriptValue(foundationObject: nil) == .undefined)
    #expect(try BrowserScriptValue(foundationObject: NSNull()) == .null)
    #expect(try BrowserScriptValue(foundationObject: true) == .bool(true))
    #expect(try BrowserScriptValue(foundationObject: 1) == .number(1))
    #expect(
      try BrowserScriptValue(jsonData: Data("[1, true]".utf8)) == .array([.number(1), .bool(true)]))
    #expect(
      try BrowserScriptValue(foundationObject: ["a": [1, "x"]])
        == .object(["a": .array([.number(1), .string("x")])]))
  }

  @Test func unsupportedTypesThrow() {
    #expect(throws: BrowserError.unsupportedScriptResult("NSObject")) {
      try BrowserScriptValue(foundationObject: NSObject())
    }
  }
}
