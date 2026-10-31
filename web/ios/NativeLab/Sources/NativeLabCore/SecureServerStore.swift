import Foundation
import Security

public struct SavedServerAccount: Codable, Equatable, Identifiable, Sendable {
  public let serverURL: URL
  public let userID: String
  public var id: String { serverURL.absoluteString + "\n" + userID }

  public init(serverURL: URL, userID: String) {
    self.serverURL = serverURL
    self.userID = userID
  }
}

public enum SecureServerStoreError: Error, LocalizedError {
  case keychain(OSStatus)
  case expired, invalidRecord

  public var errorDescription: String? {
    switch self {
    case .keychain:
      "The sign-in could not be saved in Keychain. Unlock this device and try again."
    case .expired: "Your saved sign-in has expired. Sign in again to reconnect."
    case .invalidRecord: "The saved sign-in could not be read. Sign in again."
    }
  }
}

/// Only server addresses and verified account IDs go in preferences; tokens stay in Keychain.
public struct SecureServerStore {
  private let defaults: UserDefaults
  private let service: String
  private let profilesKey = "native-server-accounts.v1"

  public init(defaults: UserDefaults = .standard, service: String = "ai.omnigent.native.servers") {
    self.defaults = defaults
    self.service = service
  }

  public var accounts: [SavedServerAccount] {
    guard let data = defaults.data(forKey: profilesKey),
      let saved = try? JSONDecoder().decode([SavedServerAccount].self, from: data)
    else { return [] }
    return saved
  }

  public func save(token: String, account: SavedServerAccount, expiresAt: Date?) throws {
    let endpoint = try ServerEndpoint(baseURL: account.serverURL)
    guard !endpoint.isLocalSingleUser, endpoint.baseURL == account.serverURL,
      !account.userID.isEmpty, expiresAt.map({ $0 > Date() }) ?? true
    else { throw SecureServerStoreError.invalidRecord }
    try ServerEndpoint.validateBearer(token)
    let data = try JSONEncoder().encode(Record(token: token, expiresAt: expiresAt))
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let query = query(account)
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw SecureServerStoreError.keychain(status) }
    var saved = accounts.filter { $0.id != account.id }
    saved.insert(account, at: 0)
    defaults.set(try JSONEncoder().encode(saved), forKey: profilesKey)
  }

  public func credential(for account: SavedServerAccount, now: Date = Date()) throws -> String {
    var request = query(account)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    guard status == errSecSuccess else { throw SecureServerStoreError.keychain(status) }
    guard let data = result as? Data,
      let record = try? JSONDecoder().decode(Record.self, from: data)
    else { throw SecureServerStoreError.invalidRecord }
    guard record.expiresAt.map({ $0 > now }) ?? true else {
      throw SecureServerStoreError.expired
    }
    return record.token
  }

  public func remove(_ account: SavedServerAccount) throws {
    let status = SecItemDelete(query(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecureServerStoreError.keychain(status)
    }
    defaults.set(
      try JSONEncoder().encode(accounts.filter { $0.id != account.id }), forKey: profilesKey)
  }

  private func query(_ account: SavedServerAccount) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account.id,
      kSecAttrSynchronizable as String: false,
    ]
  }

  private struct Record: Codable {
    let token: String
    let expiresAt: Date?
  }
}
