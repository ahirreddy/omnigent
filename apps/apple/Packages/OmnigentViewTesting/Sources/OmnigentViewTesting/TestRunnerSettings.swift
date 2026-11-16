#if os(macOS)
  import Foundation

  /// The test bundle's load calls this from C, before any test runs.
  @_cdecl("omnigent_view_testing_clear_earlier_settings")
  func clearEarlierSettings() {
    TestRunnerSettings.clearEarlierRun()
  }

  /// The test bundle's load calls this from C, before the process makes a scroll view.
  @_cdecl("omnigent_view_testing_overlay_scroll_bars")
  func overlayScrollBars() {
    TestRunnerSettings.overlayScrollBars()
  }

  /// The test bundle's load calls this from C, before the process makes a view.
  @_cdecl("omnigent_view_testing_quiet_motion")
  func quietMotion() {
    TestRunnerSettings.quietMotion()
  }

  /// `@AppStorage` saves to the test runner's own settings on disk, so a value one run leaves
  /// behind would decide what the next run's views show. Each run starts with none.
  enum TestRunnerSettings {
    /// The settings a process may clear: a test runner's own, and never an app's. A runner that
    /// splits a run over processes starts each under the runner's name and a `-` suffix, so
    /// each has settings of its own.
    /// - Parameter processName: The process's name.
    /// - Returns: The domain to clear, or `nil` for anything that isn't a test runner.
    static func domainToClear(processName: String) -> String? {
      let isRunner = ["swiftpm-testing-helper", "xctest"].contains {
        processName == $0 || (processName.hasPrefix("\($0)-") && processName.count > $0.count + 1)
      }
      return isRunner ? processName : nil
    }

    /// Clears what an earlier run saved, when this process is a test runner.
    static func clearEarlierRun() {
      if let domain = domainToClear(processName: ProcessInfo.processInfo.processName) {
        UserDefaults.standard.removePersistentDomain(forName: domain)
      }
    }

    /// The system's setting for when scroll bars show.
    static let scrollBarsKey = "AppleShowScrollBars"
    /// Scroll bars show over the content, and only during a scroll.
    static let scrollBarsWhenScrolling = "WhenScrolling"

    /// Has this process's scroll bars show over the content. Left to the system, a machine with
    /// a mouse (a VM's virtual one too) gets a bar beside the content, which is then narrower
    /// than its scroll view. Set for this process alone, over the machine's own setting.
    static func overlayScrollBars() {
      let defaults = UserDefaults.standard
      var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
      arguments[scrollBarsKey] = scrollBarsWhenScrolling
      defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    /// The setting Omnigent's views read to skip their animations, as a launch argument would.
    static let animationsKey = "OmnigentDisableAnimations"

    /// What makes this process's windows and views reach their end state at once: Omnigent's own
    /// animations, sheets sliding, window animations and animated scrolls are off. The views
    /// also announce their timed pauses, for a wait to wait them out.
    static var quietMotionSettings: [String: Any] {
      [
        animationsKey: true,
        "OmnigentReportsPauses": true,
        "NSWindowResizeTime": 0.001,
        "NSAutomaticWindowAnimationsEnabled": false,
        "NSScrollAnimationEnabled": false,
      ]
    }

    /// Turns motion off for this process alone, over the machine's own settings. A test that
    /// needs real animation sets the view's own switch back for its duration.
    static func quietMotion() {
      let defaults = UserDefaults.standard
      var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
      arguments.merge(quietMotionSettings) { _, quiet in quiet }
      defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
  }
#endif
