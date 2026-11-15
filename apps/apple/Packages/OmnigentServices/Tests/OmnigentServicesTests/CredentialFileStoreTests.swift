import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentServices

@Suite("Credential files")
struct CredentialFileStoreTests {
  private func directory() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "omnigent-credentials-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
  }

  @Test("Values round-trip per key, in files only the user can read")
  func roundTrip() throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = CredentialFileStore(directory: folder)
    let account = "https://workspace.example.com?o=42"
    let grant = SecureStoreKey(namespace: "databricks", account: account)
    let other = SecureStoreKey(namespace: "oidc", account: account)

    #expect(try store.get(key: grant) == nil)
    try store.set(key: grant, value: Data("first".utf8))
    try store.set(key: other, value: Data("other".utf8))
    try store.set(key: grant, value: Data("second".utf8))
    #expect(try store.get(key: grant) == Data("second".utf8))
    #expect(try store.get(key: other) == Data("other".utf8))

    #expect(try permissions(folder) == 0o700)
    let files = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil)
    #expect(files.count == 2)
    for file in files {
      #expect(try permissions(file) == 0o600, "\(file.lastPathComponent)")
      #expect(!file.lastPathComponent.contains("example.com"), "account names are hashed")
    }
  }

  @Test("Deleting removes the value; deleting a missing one is not an error")
  func delete() throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = CredentialFileStore(directory: folder)
    let key = SecureStoreKey(namespace: "accounts", account: "ada")
    try store.set(key: key, value: Data("token".utf8))
    try store.delete(key: key)
    #expect(try store.get(key: key) == nil)
    try store.delete(key: key)
  }

  @Test("An unreadable file is reported, not treated as missing")
  func unreadable() throws {
    let folder = directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = CredentialFileStore(directory: folder)
    let key = SecureStoreKey(namespace: "accounts", account: "ada")
    try store.set(key: key, value: Data("token".utf8))
    let file = try #require(
      FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    #expect(throws: SecureStoreError.self) { try store.get(key: key) }
  }
}
