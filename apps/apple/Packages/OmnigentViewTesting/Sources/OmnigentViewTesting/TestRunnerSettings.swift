#if os(macOS)
  import Foundation

  /// The test bundle's load calls this from C, before any test runs.
  @_cdecl("omnigent_view_testing_clear_earlier_settings")
  func clearEarlierSettings() {
    TestRunnerSettings.clearEarlierRun()
  }

  /// `@AppStorage` saves to the test runner's own settings on disk, so a value one run leaves
  /// behind would decide what the next run's views show. Each run starts with none.
  enum TestRunnerSettings {
    /// The settings a process may clear: a test runner's own, and never an app's.
    /// - Parameter processName: The process's name.
    /// - Returns: The domain to clear, or `nil` for anything that isn't a test runner.
    static func domainToClear(processName: String) -> String? {
      ["swiftpm-testing-helper", "xctest"].contains(processName) ? processName : nil
    }

    /// Clears what an earlier run saved, when this process is a test runner.
    static func clearEarlierRun() {
      guard let domain = domainToClear(processName: ProcessInfo.processInfo.processName) else {
        return
      }
      UserDefaults.standard.removePersistentDomain(forName: domain)
    }
  }
#endif
