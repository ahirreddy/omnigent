public import Foundation
public import OmnigentCoreFFI
import Security

/// Which Keychain the store uses.
public enum KeychainStorageMode: Sendable, Equatable {
  /// The data-protection keychain (`kSecUseDataProtectionKeychain`). The default, and the only
  /// mode on iOS. It needs the keychain entitlement, so unsigned command-line test binaries on
  /// macOS fail with `errSecMissingEntitlement`.
  case dataProtection
  /// The legacy file-based keychain. Works for unsigned processes, so tests use it when the
  /// data-protection keychain is unavailable to them.
  case fileBased
}

/// `SecureStore` host implementation over generic-password Keychain items.
///
/// Items are device-only (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) and never synchronize
/// through iCloud. Each `SecureStoreKey.namespace` selects a Keychain service through
/// `serviceName`, and `SecureStoreKey.account` is the item's account.
public final class KeychainSecureStore: SecureStore, Sendable {
  private let mode: KeychainStorageMode
  private let serviceName: @Sendable (String) -> String

  /// Creates a store.
  /// - Parameters:
  ///   - mode: Which Keychain to use.
  ///   - serviceName: Maps a namespace to its Keychain service. Tests inject a unique mapping so
  ///     they never touch real items.
  public init(
    mode: KeychainStorageMode = .dataProtection,
    serviceName: @escaping @Sendable (String) -> String = {
      KeychainSecureStore.defaultService(for: $0)
    }
  ) {
    self.mode = mode
    self.serviceName = serviceName
  }

  /// The production service for a namespace. These names match the existing iOS app, so
  /// credentials it stored remain readable.
  /// - Parameter namespace: The owning flow: `databricks`, `oidc` or `accounts`.
  /// - Returns: The Keychain service name.
  public static func defaultService(for namespace: String) -> String {
    switch namespace {
    case "databricks": "ai.omnigent.ios.databricks-oauth"
    case "oidc": "ai.omnigent.ios.oidc"
    case "accounts": "ai.omnigent.accounts"
    default: "ai.omnigent.\(namespace)"
    }
  }

  /// Reads the value under `key`.
  /// - Parameter key: The item to read.
  /// - Returns: The bytes, or nil when no item exists.
  /// - Throws: `SecureStoreError` when the Keychain fails.
  public func get(key: SecureStoreKey) throws(SecureStoreError) -> Data? {
    var query = baseQuery(for: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = unsafe SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data else {
        throw .Other(message: "Keychain returned a non-data value for \(describe(key))")
      }
      return data
    case errSecItemNotFound:
      return nil
    default:
      throw Self.failure(status, operation: "read \(describe(key))")
    }
  }

  /// Stores `value` under `key`, replacing any existing value.
  /// - Parameters:
  ///   - key: The item to write.
  ///   - value: The bytes to store.
  /// - Throws: `SecureStoreError` when the Keychain fails.
  public func set(key: SecureStoreKey, value: Data) throws(SecureStoreError) {
    let query = baseQuery(for: key)
    let attributes: [String: Any] = [
      kSecValueData as String: value,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    switch updateStatus {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var addQuery = query
      for (name, attribute) in attributes {
        addQuery[name] = attribute
      }
      let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw Self.failure(addStatus, operation: "write \(describe(key))")
      }
    default:
      throw Self.failure(updateStatus, operation: "update \(describe(key))")
    }
  }

  /// Removes the item under `key`. Deleting an absent item succeeds.
  /// - Parameter key: The item to remove.
  /// - Throws: `SecureStoreError` when the Keychain fails.
  public func delete(key: SecureStoreKey) throws(SecureStoreError) {
    let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Self.failure(status, operation: "delete \(describe(key))")
    }
  }

  private func baseQuery(for key: SecureStoreKey) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName(key.namespace),
      kSecAttrAccount as String: key.account,
      kSecAttrSynchronizable as String: false,
    ]
    if mode == .dataProtection {
      query[kSecUseDataProtectionKeychain as String] = true
    }
    return query
  }

  private func describe(_ key: SecureStoreKey) -> String {
    "\(serviceName(key.namespace)) account \(key.account)"
  }

  /// Maps a failed Keychain status. A locked device is `Unavailable`, which the core treats as
  /// retryable; everything else is `Other`.
  static func failure(_ status: OSStatus, operation: String) -> SecureStoreError {
    let detail = SecCopyErrorMessageString(status, nil) as String? ?? "no description"
    let message = "Keychain could not \(operation): OSStatus \(status) (\(detail))"
    if status == errSecInteractionNotAllowed {
      return .Unavailable(message: message)
    }
    return .Other(message: message)
  }
}
