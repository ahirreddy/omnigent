#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import Testing

  @testable import OmnigentPlatform

  /// The clipboard and URL shims, stopped at the recorder so nothing reaches the real Mac.
  @MainActor
  @Suite("Platform shims", .serialized)
  struct PlatformShimTests {
    init() {
      SystemSideEffects.install()
      SystemSideEffects.reset()
    }

    @Test("Copying replaces what the clipboard held, and reads back")
    func copying() {
      #expect(Pasteboard.string == nil)
      Pasteboard.copy("first")
      Pasteboard.copy("second")
      #expect(Pasteboard.string == "second")
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "second")
    }

    @Test("Unicode and empty text survive the clipboard")
    func copyingOddText() {
      for text in ["", "👩‍👩‍👧‍👦", "line\nbreak", String(repeating: "W", count: 100_000)] {
        Pasteboard.copy(text)
        #expect(Pasteboard.string == text)
      }
    }

    @Test("Opening a URL hands exactly that URL to the system")
    func opening() async throws {
      let url = try #require(URL(string: "https://example.com/a?b=c"))
      try await ExternalURLOpener.open(url)
      #expect(SystemSideEffects.record.openedURLs == [url])
    }

    @Test("A refused URL names itself")
    func refusalText() throws {
      let url = try #require(URL(string: "nope://x"))
      #expect(PlatformError.cannotOpenURL(url).description.contains("nope://x"))
    }
  }
#endif
