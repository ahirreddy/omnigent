#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentDesktopUpdate

  /// Settings' grouped form around the section, as General shows it.
  private struct UpdatesForm: View {
    let updater: SparkleUpdater
    let issue: String?

    var body: some View {
      Form { UpdateSettingsSection(updater: updater, issue: issue) }
        .formStyle(.grouped)
    }
  }

  /// Settings › General › Updates: the two switches, Check Now, Last checked and the issue line.
  @MainActor
  @Suite("Update settings", .serialized)
  struct UpdateSettingsSectionTests {
    /// The section's controls when all are enabled, top to bottom.
    private enum Control: Int {
      case automaticChecks, autoInstall, checkNow
    }

    private func hosted(
      _ driver: FakeSparkleDriver, issue: String? = nil
    ) -> OffscreenWindow<UpdatesForm> {
      OffscreenWindow(
        UpdatesForm(updater: IssueLog().updater(driver), issue: issue), width: 580, height: 400)
    }

    /// Where each control sits while all are enabled; a disabled one keeps its place.
    private func enabledLayout() throws -> [CGRect] {
      let screen = hosted(FakeSparkleDriver())
      defer { screen.close() }
      let frames = screen.controlFrames
      try #require(frames.count == 3, "\(frames)")
      return frames
    }

    private func click(
      _ control: Control, in screen: OffscreenWindow<UpdatesForm>, layout: [CGRect]
    ) throws {
      let frame = layout[control.rawValue]
      try screen.click(CGPoint(x: frame.midX, y: frame.midY))
    }

    @Test("each switch writes its own setting through to Sparkle")
    func switchesWriteThrough() throws {
      let layout = try enabledLayout()
      let driver = FakeSparkleDriver(checks: true, downloads: false)
      let screen = hosted(driver)
      defer { screen.close() }
      try click(.autoInstall, in: screen, layout: layout)
      #expect(driver.writes == [.automaticDownloads(true)])
      try click(.automaticChecks, in: screen, layout: layout)
      #expect(driver.writes == [.automaticDownloads(true), .automaticChecks(false)])
      try click(.automaticChecks, in: screen, layout: layout)
      #expect(driver.writes.last == .automaticChecks(true))
      #expect(driver.storedChecks)
      #expect(driver.storedDownloads)
    }

    @Test("a switch moved to the value Sparkle already has writes nothing")
    func matchingValueWritesNothing() throws {
      let layout = try enabledLayout()
      let driver = FakeSparkleDriver(checks: true, downloads: false)
      let screen = hosted(driver)
      defer { screen.close() }
      // Sparkle's own prompts change these behind the section's back.
      driver.storedChecks = false
      driver.storedDownloads = true
      try click(.autoInstall, in: screen, layout: layout)
      try click(.automaticChecks, in: screen, layout: layout)
      #expect(driver.writes.isEmpty)
      #expect(!driver.storedChecks)
      #expect(driver.storedDownloads)
    }

    @Test("install on quit is disabled while automatic checks are off")
    func autoInstallNeedsChecks() throws {
      let layout = try enabledLayout()
      let driver = FakeSparkleDriver(checks: true, downloads: false)
      let screen = hosted(driver)
      defer { screen.close() }
      try click(.automaticChecks, in: screen, layout: layout)
      try click(.autoInstall, in: screen, layout: layout)
      #expect(driver.writes == [.automaticChecks(false)], "the switch ignored the click")
      try click(.automaticChecks, in: screen, layout: layout)
      try click(.autoInstall, in: screen, layout: layout)
      #expect(driver.writes.suffix(2) == [.automaticChecks(true), .automaticDownloads(true)])
      let startsOff = FakeSparkleDriver(checks: false, downloads: false)
      let off = hosted(startsOff)
      defer { off.close() }
      try click(.autoInstall, in: off, layout: layout)
      #expect(startsOff.writes.isEmpty)
    }

    @Test("install on quit is disabled when the feed doesn't allow automatic updates")
    func autoInstallNeedsPermission() throws {
      let layout = try enabledLayout()
      let driver = FakeSparkleDriver(checks: true, downloads: false)
      driver.allowsAutomaticUpdates = false
      let screen = hosted(driver)
      defer { screen.close() }
      try click(.autoInstall, in: screen, layout: layout)
      #expect(driver.writes.isEmpty, "the switch ignored the click")
      try click(.automaticChecks, in: screen, layout: layout)
      #expect(driver.writes == [.automaticChecks(false)], "the section still takes clicks")
    }

    @Test("Check Now asks Sparkle to check, and is disabled while it can't")
    func checkNow() throws {
      let layout = try enabledLayout()
      let driver = FakeSparkleDriver()
      let screen = hosted(driver)
      defer { screen.close() }
      try click(.checkNow, in: screen, layout: layout)
      #expect(driver.checkCount == 1)
      let busy = FakeSparkleDriver()
      busy.canCheckForUpdates = false
      let busyScreen = hosted(busy)
      defer { busyScreen.close() }
      #expect(busyScreen.controlFrames.count == 2, "only the switches")
      try click(.checkNow, in: busyScreen, layout: layout)
      #expect(busy.checkCount == 0)
      #expect(busy.startCount == 0)
    }

    @Test("Last checked says Never before any check, then how long ago")
    func lastChecked() throws {
      let never = hosted(FakeSparkleDriver())
      defer { never.close() }
      #expect(try never.shows("Last checked"))
      #expect(try never.shownText().contains("Never"))
      let driver = FakeSparkleDriver()
      let checked = Date(timeIntervalSinceNow: -3 * 60 * 60)
      driver.lastUpdateCheckDate = checked
      let screen = hosted(driver)
      defer { screen.close() }
      let relative = checked.formatted(.relative(presentation: .named))
      let shown = try screen.shownText()
      #expect(shown.contains(relative), "\(shown)")
      #expect(!shown.contains("Never"))
    }

    @Test("the updater's issue shows only when there is one")
    func issueLine() throws {
      let issue = "Automatic updates could not start: no feed."
      let failed = hosted(FakeSparkleDriver(), issue: issue)
      defer { failed.close() }
      #expect(try failed.shownText().contains(issue))
      let fine = hosted(FakeSparkleDriver())
      defer { fine.close() }
      #expect(try fine.shows("Updates"))
      #expect(try !fine.shows("could not start"))
    }
  }
#endif
