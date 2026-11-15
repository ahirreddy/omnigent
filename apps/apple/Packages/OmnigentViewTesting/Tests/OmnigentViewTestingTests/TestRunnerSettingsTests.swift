#if os(macOS)
  import AppKit
  import Foundation
  import Testing

  @testable import OmnigentViewTesting

  @Suite("Test runner settings")
  struct TestRunnerSettingsTests {
    @Test(
      "only a test runner's own settings can be cleared",
      arguments: [
        "Omnigent Native", "Omnigent", "OmnigentMac", "ai.omnigent.mac.lab",
        "ai.omnigent.test-host",
        "", "swiftpm-testing-helper2", "XCTEST", "swiftpm-testing-helper-", "Omnigent-xctest",
      ])
    func appsAreLeftAlone(processName: String) {
      #expect(TestRunnerSettings.domainToClear(processName: processName) == nil)
    }

    @Test(
      "a test runner clears its own domain, and so does each process of a split run",
      arguments: ["swiftpm-testing-helper", "xctest", "swiftpm-testing-helper-fast3"])
    func runnersClearTheirOwn(processName: String) {
      #expect(TestRunnerSettings.domainToClear(processName: processName) == processName)
    }

    @Test("what an earlier run saved is gone")
    func clearsSavedValues() {
      let key = "omnigent.test.saved-by-an-earlier-run"
      UserDefaults.standard.set("stale", forKey: key)
      defer { UserDefaults.standard.removeObject(forKey: key) }
      TestRunnerSettings.clearEarlierRun()
      #expect(UserDefaults.standard.string(forKey: key) == nil)
    }

    @Test("a scroll view's bars take no room, whatever pointing devices the machine has")
    @MainActor
    func scrollBarsOverlayTheContent() {
      // The test bundle's load set this; the system's own choice arrives on the run loop.
      let setting = UserDefaults.standard.string(forKey: TestRunnerSettings.scrollBarsKey)
      #expect(setting == TestRunnerSettings.scrollBarsWhenScrolling)
      _ = NSScroller.preferredScrollerStyle
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
      #expect(NSScroller.preferredScrollerStyle == .overlay)
      let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
      scrollView.hasVerticalScroller = true
      scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 900))
      scrollView.tile()
      #expect(scrollView.scrollerStyle == .overlay)
      #expect(scrollView.contentView.bounds.width == 300)
    }

    @Test("the scroll bar setting keeps what the process was launched with")
    func scrollBarsKeepLaunchArguments() {
      let defaults = UserDefaults.standard
      let launched = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
      defer { defaults.setVolatileDomain(launched, forName: UserDefaults.argumentDomain) }
      let key = "omnigent.test.launch-argument"
      var arguments = launched
      arguments[key] = "kept"
      defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
      TestRunnerSettings.overlayScrollBars()
      #expect(defaults.string(forKey: key) == "kept")
      #expect(
        defaults.string(forKey: TestRunnerSettings.scrollBarsKey)
          == TestRunnerSettings.scrollBarsWhenScrolling)
    }
  }
#endif
