#if os(macOS)
  import Foundation
  import Sparkle
  import Testing

  @testable import OmnigentDesktopUpdate

  /// The wrapper over Sparkle's updater: starting it, what it forwards and which aborts it reports.
  @MainActor
  @Suite("Sparkle updater")
  struct SparkleUpdaterTests {
    private func sparkleError(_ code: SUError) -> NSError {
      NSError(domain: SUSparkleErrorDomain, code: Int(code.rawValue))
    }

    @Test("the app's updater is Sparkle's own for the main bundle, and it waits for start")
    func appUpdater() throws {
      let log = IssueLog()
      let updater = SparkleUpdater(reportIssue: { log.issues.append($0) })
      let sparkle = try #require(updater.updater as? SPUUpdater)
      #expect(sparkle.hostBundle == Bundle.main)
      #expect(!sparkle.sessionInProgress)
      #expect(!updater.canCheckForUpdates, "nothing can check before start")
      #expect(log.issues.isEmpty)
    }

    @Test("Sparkle's no-update outcome is dropped, and every other abort is reported")
    func aborts() throws {
      let log = IssueLog()
      let updater = SparkleUpdater(reportIssue: { log.issues.append($0) })
      let sparkle = try #require(updater.updater as? SPUUpdater)
      let noUpdate = sparkleError(.noUpdateError)
      let download = sparkleError(.downloadError)
      let sameCodeElsewhere = NSError(domain: NSURLErrorDomain, code: noUpdate.code)
      for error in [noUpdate, download, sameCodeElsewhere] {
        updater.callbacks.updater(sparkle, didAbortWithError: error)
      }
      #expect(
        log.summaries == [
          "update aborted: \(IssueLog.describe(download))",
          "update aborted: \(IssueLog.describe(sameCodeElsewhere))",
        ])
    }

    @Test("start starts Sparkle once and reports nothing when it starts")
    func startSucceeds() throws {
      let driver = FakeSparkleDriver()
      let log = IssueLog()
      try log.updater(driver).start()
      #expect(driver.startCount == 1)
      #expect(log.issues.isEmpty)
    }

    @Test("a start Sparkle refuses is reported as startFailed and thrown")
    func startFails() {
      let driver = FakeSparkleDriver()
      let refusal = sparkleError(.invalidFeedURLError)
      driver.startError = refusal
      let log = IssueLog()
      let updater = log.updater(driver)
      let thrown = #expect(throws: SparkleUpdaterIssue.self) { try updater.start() }
      let expected = "start failed: \(IssueLog.describe(refusal))"
      #expect(thrown.map(IssueLog.summary) == expected)
      #expect(log.summaries == [expected])
      #expect(driver.startCount == 1)
    }

    @Test("Check for Updates and the settings go straight to Sparkle")
    func forwards() {
      let checked = Date(timeIntervalSince1970: 1_800_000_000)
      let driver = FakeSparkleDriver(checks: false, downloads: true)
      driver.canCheckForUpdates = false
      driver.allowsAutomaticUpdates = false
      driver.lastUpdateCheckDate = checked
      let updater = IssueLog().updater(driver)
      #expect(!updater.canCheckForUpdates)
      #expect(!updater.allowsAutomaticUpdates)
      #expect(updater.lastUpdateCheckDate == checked)
      #expect(!updater.automaticallyChecksForUpdates)
      #expect(updater.automaticallyDownloadsUpdates)
      updater.automaticallyChecksForUpdates = true
      updater.automaticallyDownloadsUpdates = false
      #expect(driver.writes == [.automaticChecks(true), .automaticDownloads(false)])
      updater.checkForUpdates()
      #expect(driver.checkCount == 1)
      #expect(driver.startCount == 0, "checking never starts the scheduler")
    }
  }
#endif
