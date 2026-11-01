import Foundation
import OmnigentBrowser
import Testing

#if os(macOS)
  import OmnigentWebLayer
  @testable import OmnigentBrowserChromium

  @MainActor
  @Suite("Chromium provider")
  struct ChromiumProviderTests {
    private func configuration() -> ChromiumConfiguration {
      ChromiumConfiguration(
        session: SessionConfiguration(
          hostAppURL: URL(fileURLWithPath: "/nonexistent/Omnigent Web Host.app"),
          rootCacheURL: FileManager.default.temporaryDirectory.appending(path: "owl-test")))
    }

    @Test func realProviderReportsChromiumNotBundledInTestRunner() {
      let provider = DefaultBrowserEngineProvider.withChromium(configuration: configuration())
      #expect(provider.offeredEngines == [.chromium, .system])
      guard
        case .unavailable(.engineNotBundled(.chromium, let reason)) =
          provider.availability(of: .chromium)
      else {
        Issue.record("expected engineNotBundled")
        return
      }
      #expect(reason.contains("Omnigent Web Host.app"))
      #expect(throws: BrowserError.self) { try provider.engine(for: .chromium) }
      #expect(provider.availability(of: .system) == .available)
    }

    @Test func standardConfigurationPointsAtTheBundledHost() {
      let standard = ChromiumConfiguration.standard()
      #expect(standard.session.hostAppURL.path.hasSuffix("Contents/Helpers/Omnigent Web Host.app"))
      #expect(standard.session.renderMode == .remoteLayer)
    }

    @Test func hostFailuresMapToRecoverableEngineErrors() {
      #expect(
        ChromiumBrowserTab.convert(.hostExited(status: 9, reason: "killed by signal 9"))
          == .engineStopped(
            .chromium,
            reason: WebLayerError.hostExited(status: 9, reason: "killed by signal 9")
              .localizedDescription))
      #expect(ChromiumBrowserTab.convert(.notReady) == .tabNotReady)
      #expect(ChromiumBrowserTab.convert(.navigationCancelled(url: nil)).isCancellation)
      #expect(
        ChromiumBrowserTab.convert(.scriptFailed("Error: boom"))
          == .scriptFailed(message: "Error: boom"))
    }

    @Test func scriptValuesConvert() {
      let value = WebScriptValue.object(["a": .array([.number(1), .null, .bool(true)])])
      #expect(
        ChromiumBrowserTab.convert(value)
          == .object(["a": .array([.number(1), .null, .bool(true)])]))
    }
  }
#endif
