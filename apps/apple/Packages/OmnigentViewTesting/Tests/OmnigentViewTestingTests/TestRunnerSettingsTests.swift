#if os(macOS)
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
        "", "swiftpm-testing-helper2", "XCTEST",
      ])
    func appsAreLeftAlone(processName: String) {
      #expect(TestRunnerSettings.domainToClear(processName: processName) == nil)
    }

    @Test("a test runner clears its own domain", arguments: ["swiftpm-testing-helper", "xctest"])
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
  }
#endif
