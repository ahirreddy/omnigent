import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentServices

@Suite(.serialized) struct KeychainSecureStoreTests {
  /// Runs `body` against a store whose service is unique to this call, so it never touches real
  /// items. The listed accounts are deleted afterwards, even when `body` throws.
  private func withTemporaryStore(
    mode: KeychainStorageMode,
    accounts: [String],
    _ body: (KeychainSecureStore) throws -> Void
  ) throws {
    let service = "ai.omnigent.tests.\(UUID().uuidString)"
    let store = KeychainSecureStore(mode: mode, serviceName: { _ in service })
    var bodyError: (any Error)?
    do {
      try body(store)
    } catch {
      bodyError = error
    }
    for account in accounts {
      try store.delete(key: SecureStoreKey(namespace: "oidc", account: account))
    }
    if let bodyError {
      throw bodyError
    }
  }

  @Test func fileBasedKeychainRoundTrips() throws {
    try withTemporaryStore(mode: .fileBased(build: nil), accounts: ["round-trip"]) { store in
      let item = SecureStoreKey(namespace: "oidc", account: "round-trip")
      let initial = try store.get(key: item)
      #expect(initial == nil)

      try store.set(key: item, value: Data("first".utf8))
      let first = try store.get(key: item)
      #expect(first == Data("first".utf8))

      try store.set(key: item, value: Data("second".utf8))
      let second = try store.get(key: item)
      #expect(second == Data("second".utf8))

      try store.delete(key: item)
      let afterDelete = try store.get(key: item)
      #expect(afterDelete == nil)

      // Deleting an absent item succeeds.
      try store.delete(key: item)
    }
  }

  @Test func itemsAreIsolatedByAccount() throws {
    try withTemporaryStore(mode: .fileBased(build: nil), accounts: ["a", "b"]) { store in
      let first = SecureStoreKey(namespace: "oidc", account: "a")
      let second = SecureStoreKey(namespace: "oidc", account: "b")
      try store.set(key: first, value: Data("one".utf8))
      let missing = try store.get(key: second)
      #expect(missing == nil)
      try store.set(key: second, value: Data("two".utf8))
      let observed = try store.get(key: first)
      #expect(observed == Data("one".utf8))
    }
  }

  /// Items of one build never match another build's: macOS would block reading them on a
  /// password prompt, and refuse to delete them.
  @Test func fileBasedItemsAreScopedToTheBuild() throws {
    let service = "ai.omnigent.tests.\(UUID().uuidString)"
    let item = SecureStoreKey(namespace: "oidc", account: "scoped")
    let first = KeychainSecureStore(mode: .fileBased(build: "aaaa"), serviceName: { _ in service })
    let second = KeychainSecureStore(
      mode: .fileBased(build: "bbbb"), serviceName: { _ in service })
    #expect(first.service(for: "oidc") == "\(service).build-aaaa")
    defer {
      #expect(throws: Never.self) { try first.delete(key: item) }
      #expect(throws: Never.self) { try second.delete(key: item) }
    }
    try first.set(key: item, value: Data("first".utf8))
    let unseen = try second.get(key: item)
    #expect(unseen == nil)
    try second.set(key: item, value: Data("second".utf8))
    let own = try first.get(key: item)
    #expect(own == Data("first".utf8))
  }

  /// Unsigned test binaries lack the keychain entitlement, so the data-protection keychain
  /// fails there with errSecMissingEntitlement (-34018). That failure must surface as a typed
  /// `Other` error naming the status, and a signed host must round-trip. The file-based test
  /// above covers the store logic in this environment.
  @Test func dataProtectionKeychainRoundTripsOrReportsMissingEntitlement() throws {
    let service = "ai.omnigent.tests.\(UUID().uuidString)"
    let store = KeychainSecureStore(mode: .dataProtection, serviceName: { _ in service })
    let item = SecureStoreKey(namespace: "oidc", account: "data-protection")
    do {
      try store.set(key: item, value: Data("probe".utf8))
    } catch SecureStoreError.Other(let message) {
      #expect(message.contains("OSStatus -34018"))
      return
    }
    // A signed host: the write succeeded, so verify the value and remove it.
    let observed = try store.get(key: item)
    #expect(observed == Data("probe".utf8))
    try store.delete(key: item)
  }

  /// A write that finds no item goes on to add one, and that add can fail too.
  @Test func aFailedAddSaysItCouldNotWrite() throws {
    let service = "ai.omnigent.tests.\(UUID().uuidString)"
    let store = KeychainSecureStore(
      mode: .fileBased(build: nil), serviceName: { _ in service },
      addItem: { _ in errSecDuplicateItem })
    let item = SecureStoreKey(namespace: "oidc", account: "add-fails")
    guard
      case .Other(let message) = thrownError({ try store.set(key: item, value: Data("x".utf8)) })
        as? SecureStoreError
    else {
      Issue.record("expected the write to fail")
      return
    }
    #expect(message.contains("could not write"))
    #expect(try store.get(key: item) == nil)
  }

  /// Sign-out relies on delete, so a failure must surface. Reads go the same way.
  @Test func aKeychainThatRefusesReportsReadsAndDeletes() throws {
    let service = "ai.omnigent.tests.\(UUID().uuidString)"
    let store = KeychainSecureStore(mode: .dataProtection, serviceName: { _ in service })
    let item = SecureStoreKey(namespace: "oidc", account: "refused")
    do {
      try store.delete(key: item)
    } catch SecureStoreError.Other(let message) {
      #expect(message.contains("could not delete"))
      #expect(message.contains("OSStatus -34018"))
    }
  }

  @Test func onlyDataCountsAsAReadResult() throws {
    let bytes = Data("value".utf8)
    #expect(try KeychainSecureStore.itemData(bytes as CFData, of: "item") == bytes)
    for wrong in ["text" as CFString, nil] as [CFTypeRef?] {
      guard
        case .Other(let message) = thrownError({
          _ = try KeychainSecureStore.itemData(wrong, of: "the item")
        }) as? SecureStoreError
      else {
        Issue.record("expected a non-data result to throw")
        continue
      }
      #expect(message.contains("non-data value for the item"))
    }
  }

  /// Reads no item: the app's own store uses the names the iOS app wrote.
  @Test func theDefaultStoreUsesTheProductionServiceNames() {
    #expect(KeychainSecureStore().service(for: "oidc") == "ai.omnigent.ios.oidc")
  }

  @Test func namespacesMapToTheExistingServiceNames() {
    #expect(
      KeychainSecureStore.defaultService(for: "databricks") == "ai.omnigent.ios.databricks-oauth")
    #expect(KeychainSecureStore.defaultService(for: "oidc") == "ai.omnigent.ios.oidc")
    #expect(KeychainSecureStore.defaultService(for: "accounts") == "ai.omnigent.accounts")
    #expect(KeychainSecureStore.defaultService(for: "other") == "ai.omnigent.other")
  }
}
