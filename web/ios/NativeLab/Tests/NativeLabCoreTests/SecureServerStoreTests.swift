import Foundation
import XCTest

@testable import NativeLabCore

final class SecureServerStoreTests: XCTestCase {
  func testPreferencesContainOnlyAccountMetadata() throws {
    let suite = "native-keychain-tests-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SecureServerStore(defaults: defaults, service: suite)
    XCTAssertEqual(store.accounts, [])
    let account = SavedServerAccount(
      serverURL: URL(string: "https://omni.example/api/team-a")!, userID: "alice")
    XCTAssertEqual(account.id, "https://omni.example/api/team-a\nalice")
    XCTAssertFalse(
      String(decoding: try JSONEncoder().encode(account), as: UTF8.self).contains("token"))
    XCTAssertThrowsError(
      try store.save(token: "invalid\r\ntoken", account: account, expiresAt: nil))
    XCTAssertEqual(store.accounts, [])
  }

  func testKeychainSeparatesAccountsAndMountsAndDeletesOnlySelectedCredential() throws {
    guard ProcessInfo.processInfo.environment["OMNI_KEYCHAIN_TESTS"] == "1" else {
      throw XCTSkip("Set OMNI_KEYCHAIN_TESTS=1 for real isolated Keychain CRUD.")
    }
    let suite = "native-keychain-tests-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let store = SecureServerStore(defaults: defaults, service: suite)
    let first = SavedServerAccount(
      serverURL: URL(string: "https://omni.example/api/a")!, userID: "alice")
    let second = SavedServerAccount(serverURL: first.serverURL, userID: "bob")
    let third = SavedServerAccount(
      serverURL: URL(string: "https://omni.example/api/b")!, userID: "alice")
    defer {
      for account in [first, second, third] { try? store.remove(account) }
      defaults.removePersistentDomain(forName: suite)
    }
    let expiry = Date().addingTimeInterval(60)
    try store.save(token: "fixture-first", account: first, expiresAt: expiry)
    try store.save(token: "fixture-second", account: second, expiresAt: nil)
    try store.save(token: "fixture-third", account: third, expiresAt: nil)
    XCTAssertEqual(try store.credential(for: first), "fixture-first")
    XCTAssertEqual(try store.credential(for: second), "fixture-second")
    XCTAssertEqual(try store.credential(for: third), "fixture-third")
    XCTAssertThrowsError(try store.credential(for: first, now: expiry.addingTimeInterval(1)))
    let metadata = try XCTUnwrap(defaults.data(forKey: "native-server-accounts.v1"))
    XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains("fixture-"))
    try store.save(token: "fixture-updated", account: second, expiresAt: nil)
    XCTAssertEqual(store.accounts.count, 3)
    XCTAssertEqual(try store.credential(for: second), "fixture-updated")
    try store.remove(first)
    XCTAssertThrowsError(try store.credential(for: first))
    XCTAssertEqual(try store.credential(for: second), "fixture-updated")
    XCTAssertEqual(store.accounts.count, 2)
  }

  func testKeychainSeparatesDatabricksWorkspacesForTheSameAccount() throws {
    guard ProcessInfo.processInfo.environment["OMNI_KEYCHAIN_TESTS"] == "1" else {
      throw XCTSkip("Set OMNI_KEYCHAIN_TESTS=1 for real isolated Keychain CRUD.")
    }
    let suite = "native-keychain-tests-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let store = SecureServerStore(defaults: defaults, service: suite)
    let first = SavedServerAccount(
      serverURL: URL(string: "https://example.cloud.databricks.com/api/2.0/omnigent?o=123")!,
      userID: "alice")
    let second = SavedServerAccount(
      serverURL: URL(string: "https://example.cloud.databricks.com/api/2.0/omnigent?o=456")!,
      userID: "alice")
    defer {
      for account in [first, second] { try? store.remove(account) }
      defaults.removePersistentDomain(forName: suite)
    }
    try store.save(token: "fixture-workspace-a", account: first, expiresAt: nil)
    try store.save(token: "fixture-workspace-b", account: second, expiresAt: nil)
    XCTAssertEqual(try store.credential(for: first), "fixture-workspace-a")
    XCTAssertEqual(try store.credential(for: second), "fixture-workspace-b")
    try store.remove(first)
    XCTAssertThrowsError(try store.credential(for: first))
    XCTAssertEqual(try store.credential(for: second), "fixture-workspace-b")
    XCTAssertEqual(store.accounts, [second])
  }
}
