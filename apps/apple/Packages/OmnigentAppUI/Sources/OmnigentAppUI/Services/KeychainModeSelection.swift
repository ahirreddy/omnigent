import Foundation
public import OmnigentServices
import Security

/// Which Keychain this build stores credentials in.
///
/// Release always uses the data-protection keychain: a signed build carries the
/// `keychain-access-groups` entitlement, and a missing entitlement there is a packaging bug that
/// must fail loudly (the core reports the Keychain error on sign-in).
///
/// Debug builds are ad-hoc signed, and without a provisioning profile macOS refuses the
/// data-protection keychain with `errSecMissingEntitlement` (-34018). Debug probes for that once
/// and falls back to the legacy file-based keychain, reporting the fallback so it is visible.
public enum KeychainModeSelection {
  /// The chosen mode, and why when it is not the default.
  public struct Choice: Sendable, Equatable {
    /// The Keychain to use.
    public var mode: KeychainStorageMode
    /// Set when Debug fell back to the file-based keychain.
    public var fallbackReason: String?
  }

  /// Picks the mode for this build.
  /// - Returns: The data-protection keychain, or in Debug the file-based one when the
  ///   data-protection keychain is not entitled.
  public static func current() -> Choice {
    #if DEBUG && os(macOS)
      let status = probeDataProtectionKeychain()
      if status == errSecMissingEntitlement {
        return Choice(
          mode: .fileBased,
          fallbackReason:
            "This Debug build is not entitled to the data-protection keychain (OSStatus \(status)); "
            + "credentials are stored in the login keychain instead.")
      }
      return Choice(mode: .dataProtection, fallbackReason: nil)
    #else
      return Choice(mode: .dataProtection, fallbackReason: nil)
    #endif
  }

  #if DEBUG && os(macOS)
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
