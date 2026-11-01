import Foundation
import OmnigentBrowser
import Testing

#if os(macOS)
  import OmnigentBrowserChromium

  @MainActor
  @Suite("Chromium provider")
  struct ChromiumProviderTests {
    @Test func realProviderReportsChromiumNotBundledInTestRunner() {
      let provider = DefaultBrowserEngineProvider.withChromium(
        configuration: ChromiumConfiguration(
          helperName: "Missing Helper",
          rootCacheURL: FileManager.default.temporaryDirectory.appending(path: "cef-test")))
      #expect(provider.offeredEngines == [.chromium, .system])
      guard
        case .unavailable(.engineNotBundled(.chromium, let reason)) =
          provider.availability(of: .chromium)
      else {
        Issue.record("expected engineNotBundled")
        return
      }
      #expect(!reason.isEmpty)
      #expect(throws: BrowserError.self) { try provider.engine(for: .chromium) }
      #expect(provider.availability(of: .system) == .available)
    }
  }
#endif
