import Foundation
// Re-exports libghostty's C API (`ghostty.h`, module `GhosttyKit`) with the link settings every
// client needs. Swift code imports `OmnigentGhosttyKit` and never links GhosttyKit directly.
@_exported public import GhosttyKit

/// The libghostty build this package links, from `ghostty_info()`.
public enum GhosttyBuildInfo {
  /// The version string, for example `1.3.2-dev+omnigent.2c1a19d7e4fa`.
  public static var version: String {
    let info = unsafe ghostty_info()
    guard let pointer = unsafe info.version else { return "" }
    let bytes = unsafe UnsafeRawBufferPointer(start: pointer, count: Int(info.version_len))
    return unsafe String(bytes: bytes, encoding: .utf8) ?? "(not UTF-8)"
  }
}
