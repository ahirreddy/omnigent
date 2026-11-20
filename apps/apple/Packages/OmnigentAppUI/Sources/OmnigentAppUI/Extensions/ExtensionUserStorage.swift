import Foundation
import OmnigentCoreFFI

/// What an extension keeps for its user (`storage.user`), on this device, by server, user and
/// extension, with the web's limits: 256 KB and 128 keys an extension, 32 KB a value (the core
/// checks keys and values). Each extension's values are one defaults entry of JSON texts.
@MainActor
final class ExtensionUserStorage {
  /// The most an extension may keep, in UTF-8 bytes of its values' JSON.
  static let maxBytes = 256 * 1024
  /// The most keys an extension may keep.
  static let maxKeys = 128

  private let defaults: UserDefaults
  private let key: String

  /// Storage for one extension of one user on one server.
  /// - Parameters:
  ///   - server: The server's base URL.
  ///   - userID: The signed-in user.
  ///   - extensionID: The extension.
  ///   - defaults: Where values are kept.
  init(server: String, userID: String, extensionID: String, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let parts = [server, userID, extensionID].map {
      $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0
    }
    key = "omnigent.extension-storage.v1/" + parts.joined(separator: "/")
  }

  private var values: [String: String] {
    defaults.dictionary(forKey: key) as? [String: String] ?? [:]
  }

  /// The value under `key` as JSON text, or `nil` when there is none.
  func get(_ key: String) -> String? {
    values[key]
  }

  /// Keeps `write`'s value under its key.
  /// - Throws: `QuotaExceeded` when it would take the extension past its limits.
  func set(_ write: ExtensionStorageWrite) throws(ExtensionHostFault) {
    var stored = values
    stored[write.key] = write.json
    let bytes = stored.values.reduce(0) { $0 + $1.utf8.count }
    guard bytes <= Self.maxBytes, stored.count <= Self.maxKeys else {
      throw .Failed(code: "QuotaExceeded", message: "Extension storage quota exceeded")
    }
    defaults.set(stored, forKey: key)
  }

  /// Removes the value under `key`, if any.
  func delete(_ key: String) {
    var stored = values
    guard stored.removeValue(forKey: key) != nil else { return }
    defaults.set(stored, forKey: self.key)
  }
}
