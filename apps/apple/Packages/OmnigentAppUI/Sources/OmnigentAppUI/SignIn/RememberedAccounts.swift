import Foundation
import OmnigentCoreFFI

/// The account last signed in on each accounts-mode server, so the next connect can ask the core
/// to restore that account's saved credential. Only the user id is stored here; the credential
/// itself stays in the Keychain, owned by the core.
struct RememberedAccounts {
  static let defaultsKey = "omnigent.accountsUsers"

  let defaults: UserDefaults

  func user(for serverURL: String) -> String? {
    users()[Self.key(serverURL)]
  }

  func remember(_ server: ConnectedServer) {
    guard case .accounts = server.mode else { return }
    var users = users()
    users[Self.key(server.baseUrl)] = server.userId
    defaults.set(users, forKey: Self.defaultsKey)
  }

  func forget(_ serverURL: String) {
    var users = users()
    users[Self.key(serverURL)] = nil
    defaults.set(users, forKey: Self.defaultsKey)
  }

  private func users() -> [String: String] {
    defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
  }

  /// Typed and canonical forms of a server share one entry: no trailing slash, lowercased.
  private static func key(_ serverURL: String) -> String {
    var key = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while key.hasSuffix("/") { key.removeLast() }
    return key
  }
}
