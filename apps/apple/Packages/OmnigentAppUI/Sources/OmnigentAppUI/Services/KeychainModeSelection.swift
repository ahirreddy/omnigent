public import Foundation
public import OmnigentServices
import Security

/// Where this build stores credentials.
///
/// A team-signed build uses the data-protection keychain: it carries the `keychain-access-groups`
/// entitlement, and a missing entitlement there is a packaging bug that must fail loudly (the core
/// reports the Keychain error on sign-in).
///
/// A Mac build without a team (Debug, or a Release built and signed locally) has no provisioning
/// profile, and macOS refuses it the data-protection keychain with `errSecMissingEntitlement`
/// (-34018). The login keychain is no substitute: without an Apple-issued team ID it ties each
/// item to the exact build that saved it, so every rebuild either loses its sign-ins or blocks on
/// a keychain prompt. Such a build probes for the entitlement once and otherwise keeps credentials
/// in files only the user can read (``CredentialFileStore``), reporting the fallback so it is
/// visible.
public enum KeychainModeSelection {
  /// The chosen storage, and why when it is not the default.
  public struct Choice: Sendable, Equatable {
    /// The Keychain to use when ``credentialDirectory`` is nil.
    public var mode: KeychainStorageMode
    /// For a build without a team: keep credentials in files here instead of the Keychain.
    public var credentialDirectory: URL?
    /// Set when the build fell back to credential files.
    public var fallbackReason: String?
  }

  /// Picks the storage for this build.
  /// - Returns: The data-protection keychain, or for a Mac build without a team credential
  ///   files when the data-protection keychain is not entitled.
  public static func current() -> Choice {
    #if os(macOS)
      #if DEBUG
        let kind = "Debug build"
        let folder = "DebugCredentials"
      #else
        // A team-signed release must keep failing loudly without the entitlement.
        guard !hasTeamIdentifier() else {
          return Choice(mode: .dataProtection, credentialDirectory: nil, fallbackReason: nil)
        }
        let kind = "locally signed build"
        let folder = "LocalCredentials"
      #endif
      let status = probeDataProtectionKeychain()
      guard status == errSecMissingEntitlement else {
        return Choice(mode: .dataProtection, credentialDirectory: nil, fallbackReason: nil)
      }
      let directory = credentialDirectory(folder)
      return Choice(
        mode: .dataProtection, credentialDirectory: directory,
        fallbackReason:
          "This \(kind) is not entitled to the data-protection keychain (OSStatus \(status)); "
          + "credentials are kept in files only you can read, in \(directory.path), so they "
          + "survive rebuilds. Team-signed builds use the keychain.")
    #else
      return Choice(mode: .dataProtection, credentialDirectory: nil, fallbackReason: nil)
    #endif
  }

  #if os(macOS)
    /// `Application Support/<bundle id>/<folder>`.
    static func credentialDirectory(_ folder: String) -> URL {
      URL.applicationSupportDirectory
        .appending(path: Bundle.main.bundleIdentifier ?? "ai.omnigent", directoryHint: .isDirectory)
        .appending(path: folder, directoryHint: .isDirectory)
    }

    /// Whether the running app is signed by an Apple-issued team. Ad-hoc and self-signed builds
    /// are not; nor is a binary whose signature cannot be read.
    static func hasTeamIdentifier() -> Bool {
      var code: SecCode?
      guard unsafe SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
      var staticCode: SecStaticCode?
      guard unsafe SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
        let staticCode
      else { return false }
      var information: CFDictionary?
      guard
        unsafe SecCodeCopySigningInformation(
          staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
          == errSecSuccess,
        let information = information as? [String: Any]
      else { return false }
      let team = information[kSecCodeInfoTeamIdentifier as String] as? String
      return team.map { !$0.isEmpty } ?? false
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
