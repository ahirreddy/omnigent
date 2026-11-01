import Darwin
import OmnigentGhosttyKit
import Testing

/// Code linked into the same image as libghostty must still get C's `memset`.
///
/// libghostty exports a hidden `memset` (`src/quirks_memset.zig`) whose fill parameter is a Zig
/// `u8`. In a static link every other object in the image binds to it, and C's prototype passes
/// `int c`: Rust lowers `ptr::write_bytes(p, 0xFF, n)` to `memset(p, -1, n)`. The quirk splats the
/// whole int, so a 0xFF fill wrote `FF FE FE FE`, which corrupted hashbrown's control bytes and
/// froze the Rust core on iOS, where the core and libghostty share one image.
@Suite("libc symbols linked beside GhosttyKit")
struct LibcBindingTests {
  @Test(
    "memset converts its int fill to unsigned char",
    arguments: [1, 3, 4, 7, 8, 12, 15, 16, 31, 32, 33, 64, 200, 20_000])
  func memsetTruncatesFill(length: Int) {
    // Keeps libghostty's objects (and so its memset) in this test image.
    #expect(GhosttyBuildInfo.version.contains("omnigent."))
    var buffer = [UInt8](repeating: 0xAA, count: length + 2)
    // Guard bytes on both sides; C's `memset(p, -1, n)` must fill exactly n bytes of 0xFF.
    buffer[1...length].withUnsafeMutableBytes { bytes in
      _ = unsafe memset(bytes.baseAddress, -1, bytes.count)
    }
    #expect(buffer.first == 0xAA)
    #expect(buffer.last == 0xAA)
    let filled = buffer.dropFirst().dropLast()
    #expect(filled.allSatisfy { $0 == 0xFF }, "fill bytes: \(Array(filled.prefix(16)))")
  }
}
