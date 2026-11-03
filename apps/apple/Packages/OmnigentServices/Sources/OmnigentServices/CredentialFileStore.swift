import CryptoKit
public import Foundation
public import OmnigentCoreFFI

/// `SecureStore` over plain files, one per key, in a directory only the user can read (0700, files
/// 0600). For Debug Mac builds only: without an Apple-issued team ID macOS ties each login
/// keychain item to the exact build that saved it, so every rebuild lost its sign-ins or blocked
/// on a keychain prompt (see `KeychainModeSelection`). Release builds use the keychain.
public final class CredentialFileStore: SecureStore, Sendable {
  private let directory: URL

  /// A store in `directory`, created on the first write.
  /// - Parameter directory: Where the files live, for example the app's Application Support.
  public init(directory: URL) {
    self.directory = directory
  }

  /// Reads the value under `key`.
  /// - Parameter key: The item to read.
  /// - Returns: The bytes, or nil when no item exists.
  /// - Throws: `SecureStoreError` when the file cannot be read.
  public func get(key: SecureStoreKey) throws(SecureStoreError) -> Data? {
    let file = file(for: key)
    do {
      return try Data(contentsOf: file)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    } catch {
      throw .Other(message: "Could not read \(describe(key)) from \(file.path): \(error)")
    }
  }

  /// Stores `value` under `key`, replacing any existing value, readable only by the user.
  /// - Parameters:
  ///   - key: The item to write.
  ///   - value: The bytes to store.
  /// - Throws: `SecureStoreError` when the file cannot be written.
  public func set(key: SecureStoreKey, value: Data) throws(SecureStoreError) {
    let file = file(for: key)
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
      try value.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } catch {
      throw .Other(message: "Could not write \(describe(key)) to \(file.path): \(error)")
    }
  }

  /// Deletes the value under `key`; a missing one is not an error.
  /// - Parameter key: The item to delete.
  /// - Throws: `SecureStoreError` when the file cannot be removed.
  public func delete(key: SecureStoreKey) throws(SecureStoreError) {
    let file = file(for: key)
    do {
      try FileManager.default.removeItem(at: file)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    } catch {
      throw .Other(message: "Could not delete \(describe(key)) at \(file.path): \(error)")
    }
  }

  /// `<namespace>-<SHA-256 of the account>`: the account can be any string, a URL included.
  private func file(for key: SecureStoreKey) -> URL {
    let digest = SHA256.hash(data: Data(key.account.utf8))
    let account = digest.map { byte in
      let digits = String(byte, radix: 16)
      return byte < 0x10 ? "0" + digits : digits
    }.joined()
    let namespace = key.namespace.filter { $0.isLetter || $0.isNumber || $0 == "-" }
    return directory.appending(path: "\(namespace)-\(account)", directoryHint: .notDirectory)
  }

  private func describe(_ key: SecureStoreKey) -> String {
    "the \(key.namespace) credential"
  }
}
