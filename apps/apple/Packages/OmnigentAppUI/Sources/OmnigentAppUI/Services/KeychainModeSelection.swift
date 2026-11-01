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
/// The fallback's items are scoped to the build's code directory hash (see
/// ``KeychainStorageMode/fileBased(build:)``): an item another build saved would otherwise
/// block the launch on a login keychain password prompt.
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
      guard status == errSecMissingEntitlement else {
        return Choice(mode: .dataProtection, fallbackReason: nil)
      }
      let reason =
        "This Debug build is not entitled to the data-protection keychain (OSStatus \(status)); "
        + "credentials are stored in the login keychain instead"
      switch buildIdentity() {
      case .success(let build):
        return Choice(
          mode: .fileBased(build: build),
          fallbackReason:
            "\(reason), scoped to this build (\(build)), so a rebuilt app asks you to sign in again.")
      case .failure(let error):
        return Choice(
          mode: .fileBased(build: nil),
          fallbackReason:
            "\(reason), shared across builds because this build's identity is unknown "
            + "(\(error.message)). Credentials another build saved ask for the login keychain "
            + "password.")
      }
    #else
      return Choice(mode: .dataProtection, fallbackReason: nil)
    #endif
  }

  #if DEBUG && os(macOS)
    /// Why the running build's identity could not be read.
    struct BuildIdentityError: Error {
      let message: String
    }

    /// The running build's code directory hash in hex: the identity macOS ties file-based
    /// keychain items of an ad-hoc signed binary to.
    static func buildIdentity() -> Result<String, BuildIdentityError> {
      var code: SecCode?
      var status = unsafe SecCodeCopySelf([], &code)
      guard status == errSecSuccess, let code else {
        return .failure(BuildIdentityError(message: "SecCodeCopySelf: OSStatus \(status)"))
      }
      var staticCode: SecStaticCode?
      status = unsafe SecCodeCopyStaticCode(code, [], &staticCode)
      guard status == errSecSuccess, let staticCode else {
        return .failure(BuildIdentityError(message: "SecCodeCopyStaticCode: OSStatus \(status)"))
      }
      var information: CFDictionary?
      status = unsafe SecCodeCopySigningInformation(staticCode, [], &information)
      guard status == errSecSuccess, let information = information as? [String: Any] else {
        return .failure(
          BuildIdentityError(message: "SecCodeCopySigningInformation: OSStatus \(status)"))
      }
      guard let hash = information[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else {
        return .failure(BuildIdentityError(message: "the binary has no code directory hash"))
      }
      let hex = hash.map { byte in
        let digits = String(byte, radix: 16)
        return byte < 0x10 ? "0" + digits : digits
      }
      return .success(hex.joined())
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
