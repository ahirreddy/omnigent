public import Foundation
public import OmnigentServices
import Security

/// Where this build stores credentials.
///
/// Release always uses the data-protection keychain: a signed build carries the
/// `keychain-access-groups` entitlement, and a missing entitlement there is a packaging bug that
/// must fail loudly (the core reports the Keychain error on sign-in).
///
/// Debug builds have no provisioning profile, and macOS refuses them the data-protection keychain
/// with `errSecMissingEntitlement` (-34018). The login keychain is no substitute: without an
/// Apple-issued team ID it ties each item to the exact build that saved it, so every rebuild
/// either loses its sign-ins or blocks on a keychain prompt. Debug probes for the entitlement once
/// and otherwise keeps credentials in files only the user can read (``CredentialFileStore``),
/// reporting the fallback so it is visible.
public enum KeychainModeSelection {
  /// The chosen storage, and why when it is not the default.
  public struct Choice: Sendable, Equatable {
    /// The Keychain to use when ``credentialDirectory`` is nil.
    public var mode: KeychainStorageMode
    /// Debug only: keep credentials in files here instead of the Keychain.
    public var credentialDirectory: URL?
    /// Set when Debug fell back to credential files.
    public var fallbackReason: String?
  }

  /// Picks the storage for this build.
  /// - Returns: The data-protection keychain, or in Debug credential files when the
  ///   data-protection keychain is not entitled.
  public static func current() -> Choice {
    #if DEBUG && os(macOS)
      let status = probeDataProtectionKeychain()
      guard status == errSecMissingEntitlement else {
        return Choice(mode: .dataProtection, credentialDirectory: nil, fallbackReason: nil)
      }
      let directory = debugCredentialDirectory()
      return Choice(
        mode: .dataProtection, credentialDirectory: directory,
        fallbackReason:
          "This Debug build is not entitled to the data-protection keychain (OSStatus \(status)); "
          + "credentials are kept in files only you can read, in \(directory.path), so they "
          + "survive rebuilds. Release builds use the keychain.")
    #else
      return Choice(mode: .dataProtection, credentialDirectory: nil, fallbackReason: nil)
    #endif
  }

  #if DEBUG && os(macOS)
    /// `Application Support/<bundle id>/DebugCredentials`.
    static func debugCredentialDirectory() -> URL {
      URL.applicationSupportDirectory
        .appending(path: Bundle.main.bundleIdentifier ?? "ai.omnigent", directoryHint: .isDirectory)
        .appending(path: "DebugCredentials", directoryHint: .isDirectory)
    }

    /// Deletes an item that never exists. An entitled process gets `errSecItemNotFound`; an
    /// unentitled one `errSecMissingEntitlement`. (A read is no probe: lookups in the
    /// data-protection keychain answer "not found" even without the entitlement, and only
    /// writes and deletes are refused.)
    private static func probeDataProtectionKeychain() -> OSStatus {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "ai.omnigent.keychain-probe",
        kSecAttrAccount as String: "probe",
        kSecUseDataProtectionKeychain as String: true,
      ]
      return SecItemDelete(query as CFDictionary)
    }
  #endif
}
