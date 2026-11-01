public import Foundation
public import OmnigentCoreFFI
import Security

/// `EntropySource` host implementation backed by `SecRandomCopyBytes`.
public final class SystemEntropySource: EntropySource, Sendable {
  /// Creates an entropy source.
  public init() {}

  /// Returns exactly `len` cryptographically secure random bytes.
  /// - Parameter len: The number of bytes.
  /// - Returns: The bytes.
  /// - Throws: `EntropyError.Unavailable` when the system RNG fails.
  public func randomBytes(len: UInt32) throws(EntropyError) -> Data {
    guard len > 0 else { return Data() }
    var bytes = [UInt8](repeating: 0, count: Int(len))
    let status = unsafe SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw .Unavailable(message: "SecRandomCopyBytes failed with OSStatus \(status)")
    }
    return Data(bytes)
  }
}
