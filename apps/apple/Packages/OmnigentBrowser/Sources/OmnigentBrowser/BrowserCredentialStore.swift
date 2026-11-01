internal import Foundation
internal import Security

/// Where HTTP authentication credentials are kept when the user opts in. Nothing is stored
/// unless the user ticks "Remember in Keychain", and never for ephemeral profiles.
public protocol BrowserCredentialStore: AnyObject {
  /// The stored credential for `space`, if any.
  func credential(for space: BrowserProtectionSpace) throws(BrowserError) -> BrowserCredential?
  /// Stores or replaces the credential for `space`.
  func save(_ credential: BrowserCredential, for space: BrowserProtectionSpace)
    throws(BrowserError)
  /// Removes the credential for `space`. Missing items are not an error.
  func removeCredential(for space: BrowserProtectionSpace) throws(BrowserError)
}

/// Internet passwords in the user's Keychain, tagged so only this app's browser items are read.
public final class KeychainBrowserCredentialStore: BrowserCredentialStore {
  /// The app-wide store.
  public static let shared = KeychainBrowserCredentialStore()

  /// Marks the items this store owns (`kSecAttrDescription`).
  public let itemDescription: String

  /// Creates a store; tests pass their own description to stay apart from real items.
  public init(itemDescription: String = "Omnigent Browser Password") {
    self.itemDescription = itemDescription
  }

  private func query(for space: BrowserProtectionSpace) -> [String: Any] {
    [
      kSecClass as String: kSecClassInternetPassword,
      kSecAttrServer as String: space.host,
      kSecAttrPort as String: space.port,
      kSecAttrSecurityDomain as String: space.realm,
      kSecAttrProtocol as String: space.isSecure ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP,
      kSecAttrDescription as String: itemDescription,
    ]
  }

  /// See `BrowserCredentialStore.credential(for:)`.
  public func credential(for space: BrowserProtectionSpace) throws(BrowserError)
    -> BrowserCredential?
  {
    var request = query(for: space)
    request[kSecReturnAttributes as String] = true
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else { throw Self.failure("reading", status) }
    guard let item = result as? [String: Any],
      let account = item[kSecAttrAccount as String] as? String,
      let data = item[kSecValueData as String] as? Data,
      let password = String(bytes: data, encoding: .utf8)
    else {
      throw .credentialStoreFailed("The Keychain item for \(space.host) is malformed.")
    }
    return BrowserCredential(username: account, password: password)
  }

  /// See `BrowserCredentialStore.save(_:for:)`.
  public func save(_ credential: BrowserCredential, for space: BrowserProtectionSpace)
    throws(BrowserError)
  {
    try removeCredential(for: space)
    var item = query(for: space)
    item[kSecAttrAccount as String] = credential.username
    item[kSecValueData as String] = Data(credential.password.utf8)
    item[kSecAttrLabel as String] = "\(space.host) (\(itemDescription))"
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw Self.failure("saving", status) }
  }

  /// See `BrowserCredentialStore.removeCredential(for:)`.
  public func removeCredential(for space: BrowserProtectionSpace) throws(BrowserError) {
    let status = SecItemDelete(query(for: space) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Self.failure("removing", status)
    }
  }

  private static func failure(_ operation: String, _ status: OSStatus) -> BrowserError {
    let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    return .credentialStoreFailed("Keychain \(operation) failed: \(message) (\(status)).")
  }
}

/// Keeps credentials in memory; for tests and previews.
public final class InMemoryBrowserCredentialStore: BrowserCredentialStore {
  private var items: [BrowserProtectionSpace: BrowserCredential] = [:]

  /// Creates an empty store.
  public init() {}

  /// See `BrowserCredentialStore.credential(for:)`.
  public func credential(for space: BrowserProtectionSpace) -> BrowserCredential? {
    items[space]
  }

  /// See `BrowserCredentialStore.save(_:for:)`.
  public func save(_ credential: BrowserCredential, for space: BrowserProtectionSpace) {
    items[space] = credential
  }

  /// See `BrowserCredentialStore.removeCredential(for:)`.
  public func removeCredential(for space: BrowserProtectionSpace) {
    items[space] = nil
  }
}
