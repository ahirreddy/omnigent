import Foundation
import Security
import Testing

@testable import OmnigentBrowser

/// Answers the store's Keychain calls with what the test set, and records what it asked for.
@MainActor
private final class FakeKeychain {
  var copyAnswer: (status: OSStatus, item: CFTypeRef?) = (errSecItemNotFound, nil)
  var addStatus = errSecSuccess
  var deleteStatus = errSecSuccess
  private(set) var copied: [[String: Any]] = []
  private(set) var added: [[String: Any]] = []
  private(set) var deleted: [[String: Any]] = []
  private(set) var order: [String] = []

  var calls: KeychainItemCalls {
    KeychainItemCalls(
      copyMatching: { [self] query in
        copied.append(query)
        return copyAnswer
      },
      add: { [self] item in
        added.append(item)
        order.append("add")
        return addStatus
      },
      delete: { [self] query in
        deleted.append(query)
        order.append("delete")
        return deleteStatus
      })
  }
}

@MainActor
@Suite("The Keychain credential store, behind fake calls", .serialized)
struct KeychainStoreCallTests {
  private let secure = BrowserProtectionSpace(
    host: "a.example", port: 8443, realm: "Staff", scheme: "basic", isProxy: false, isSecure: true)
  private let plain = BrowserProtectionSpace(
    host: "b.example", port: 80, realm: "Open", scheme: "basic", isProxy: false, isSecure: false)

  private func store(_ keychain: FakeKeychain) -> KeychainBrowserCredentialStore {
    KeychainBrowserCredentialStore(itemDescription: "Tests", calls: keychain.calls)
  }

  /// The message of the store failure `body` must throw.
  private func failure(_ body: () throws(BrowserError) -> Void) -> String {
    do throws(BrowserError) {
      try body()
      Issue.record("expected a Keychain failure")
      return ""
    } catch {
      guard case .credentialStoreFailed(let message) = error else {
        Issue.record("expected credentialStoreFailed, got \(error)")
        return ""
      }
      return message
    }
  }

  @Test("the app-wide store owns items by its own description")
  func sharedStore() {
    #expect(KeychainBrowserCredentialStore.shared.itemDescription == "Omnigent Browser Password")
  }

  @Test("a lookup asks only for this store's item for that site, with its secret")
  func lookupQuery() throws {
    let keychain = FakeKeychain()
    #expect(try store(keychain).credential(for: secure) == nil)
    #expect(try store(keychain).credential(for: plain) == nil)
    let first = try #require(keychain.copied.first)
    #expect(first[kSecAttrServer as String] as? String == "a.example")
    #expect(first[kSecAttrPort as String] as? Int == 8443)
    #expect(first[kSecAttrSecurityDomain as String] as? String == "Staff")
    #expect(first[kSecAttrDescription as String] as? String == "Tests")
    #expect(first[kSecReturnData as String] as? Bool == true)
    #expect(first[kSecAttrProtocol as String] as? String == kSecAttrProtocolHTTPS as String)
    #expect(
      keychain.copied[1][kSecAttrProtocol as String] as? String == kSecAttrProtocolHTTP as String)
  }

  @Test("a stored item comes back as the credential")
  func lookupFinds() throws {
    let keychain = FakeKeychain()
    let item: [String: Any] = [
      kSecAttrAccount as String: "owl", kSecValueData as String: Data("pässword".utf8),
    ]
    keychain.copyAnswer = (errSecSuccess, item as CFDictionary)
    #expect(
      try store(keychain).credential(for: secure)
        == BrowserCredential(username: "owl", password: "pässword"))
  }

  @Test("an item without a name, a secret or readable text is reported, not used")
  func malformedItems() {
    let account = kSecAttrAccount as String
    let secret = kSecValueData as String
    let items: [CFTypeRef?] = [
      nil, "not a dictionary" as CFString,
      [secret: Data("x".utf8)] as CFDictionary,
      [account: "owl"] as CFDictionary,
      [account: "owl", secret: Data([0xFF, 0xFE])] as CFDictionary,
    ]
    for item in items {
      let keychain = FakeKeychain()
      keychain.copyAnswer = (errSecSuccess, item)
      let message = failure { () throws(BrowserError) in
        _ = try store(keychain).credential(for: secure)
      }
      #expect(message == "The Keychain item for a.example is malformed.")
    }
  }

  @Test("a refused lookup says what failed and the status")
  func lookupRefused() {
    let keychain = FakeKeychain()
    keychain.copyAnswer = (errSecAuthFailed, nil)
    let message = failure { () throws(BrowserError) in
      _ = try store(keychain).credential(for: secure)
    }
    #expect(message.hasPrefix("Keychain reading failed: "))
    #expect(message.hasSuffix("(\(errSecAuthFailed))."))
  }

  @Test("saving replaces the old item and stores the name, secret and a readable label")
  func saveReplaces() throws {
    let keychain = FakeKeychain()
    try store(keychain).save(BrowserCredential(username: "owl", password: "pw"), for: secure)
    #expect(keychain.order == ["delete", "add"])
    let item = try #require(keychain.added.first)
    #expect(item[kSecAttrAccount as String] as? String == "owl")
    #expect(item[kSecValueData as String] as? Data == Data("pw".utf8))
    #expect(item[kSecAttrLabel as String] as? String == "a.example (Tests)")
    #expect(item[kSecAttrServer as String] as? String == "a.example")
  }

  @Test("saving over nothing still adds; a refused add or delete is reported")
  func saveFailures() {
    let credential = BrowserCredential(username: "owl", password: "pw")
    let first = FakeKeychain()
    first.deleteStatus = errSecItemNotFound
    first.addStatus = errSecDuplicateItem
    let saving = failure { () throws(BrowserError) in
      try store(first).save(credential, for: secure)
    }
    #expect(saving.hasPrefix("Keychain saving failed: "))
    #expect(first.added.count == 1)

    let second = FakeKeychain()
    second.deleteStatus = errSecAuthFailed
    let removing = failure { () throws(BrowserError) in
      try store(second).save(credential, for: secure)
    }
    #expect(removing.hasPrefix("Keychain removing failed: "))
    #expect(second.added.isEmpty)
  }

  @Test("removing something already gone isn't an error")
  func removeMissing() throws {
    let keychain = FakeKeychain()
    keychain.deleteStatus = errSecItemNotFound
    try store(keychain).removeCredential(for: plain)
    #expect(keychain.deleted.count == 1)
    #expect(keychain.deleted[0][kSecAttrServer as String] as? String == "b.example")
  }

  @Test("a status the system has no words for still reads as its number")
  func unknownStatus() {
    let keychain = FakeKeychain()
    keychain.deleteStatus = -999_999
    let message = failure { () throws(BrowserError) in
      try store(keychain).removeCredential(for: plain)
    }
    #expect(message.hasPrefix("Keychain removing failed: "))
    #expect(message.hasSuffix("(-999999)."))
  }
}
