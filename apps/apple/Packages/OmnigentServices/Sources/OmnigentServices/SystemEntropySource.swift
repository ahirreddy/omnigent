public import Foundation
public import OmnigentCoreFFI
import Security

/// `EntropySource` host implementation backed by `SecRandomCopyBytes`.
public final class SystemEntropySource: EntropySource, Sendable {
  private let fill: @Sendable (inout [UInt8]) -> OSStatus

  /// Creates an entropy source over the system's generator.
  public convenience init() {
    self.init(fill: { bytes in unsafe SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) })
  }

  /// Creates an entropy source over `fill`, which overwrites the bytes and returns its status.
  init(fill: @escaping @Sendable (inout [UInt8]) -> OSStatus) {
    self.fill = fill
  }

  /// Returns exactly `len` cryptographically secure random bytes.
  /// - Parameter len: The number of bytes.
  /// - Returns: The bytes.
  /// - Throws: `EntropyError.Unavailable` when the system RNG fails.
  public func randomBytes(len: UInt32) throws(EntropyError) -> Data {
    guard len > 0 else { return Data() }
    var bytes = [UInt8](repeating: 0, count: Int(len))
    let status = fill(&bytes)
    guard status == errSecSuccess else {
      throw .Unavailable(message: "SecRandomCopyBytes failed with OSStatus \(status)")
    }
    return Data(bytes)
  }
}
