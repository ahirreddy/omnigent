#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentBrowser

  /// Answers engine calls with failures, to reach the views' error lines.
  @MainActor
  private final class FailingDataProvider: BrowserEngineProvider {
    func availability(of kind: BrowserEngineKind) -> BrowserEngineAvailability { .available }
    func engine(for kind: BrowserEngineKind) throws(BrowserError) -> any BrowserEngine {
      throw .engineFailedToStart(kind, reason: "no engine")
    }
  }

  @MainActor
  @Suite("Downloads, off screen", .serialized)
  struct DownloadsViewTests {
    private func download(
      name: String = "report.pdf", total: Int64? = nil, received: Int64 = 0,
      state: BrowserDownloadState = .inProgress, profile: String? = nil,
      cancel: @escaping () throws(BrowserError) -> Void = {}
    ) -> BrowserDownload {
      let item = BrowserDownload(
        url: nil, suggestedName: name, destination: URL(fileURLWithPath: "/tmp/\(name)"),
        engine: .system, totalBytes: total, cancel: cancel)
      item.receivedBytes = received
      item.state = state
      item.profileIdentifier = profile
      return item
    }

    @Test("the line under a download says how far it got")
    func statusText() {
      let bytes = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
      let status = { BrowserDownloadRow.statusText($0) }
      #expect(status(download(received: 2_000)) == bytes(2_000))
      #expect(
        status(download(total: 8_000, received: 2_000)) == "\(bytes(2_000)) of \(bytes(8_000))")
      #expect(status(download(received: 2_000, state: .paused)) == "Paused at \(bytes(2_000))")
      #expect(status(download(received: 2_000, state: .complete)) == "Done, \(bytes(2_000))")
      #expect(status(download(state: .cancelled)) == "Cancelled")
      #expect(status(download(state: .failed("disk full"))) == "Failed: disk full")
    }

    @Test("an empty list says so; a profile sees only its own downloads")
    func emptyAndFiltered() async throws {
      SystemSideEffects.install()
      let center = BrowserDownloadCenter()
      let settings = BrowserDownloadSettings(defaults: try isolatedDefaults())
      center.add(download(profile: "other"))
      let screen = OffscreenWindow(
        BrowserDownloadsView(center: center, settings: settings, profileIdentifier: "mine"),
        width: 420, height: 320)
      defer { screen.close() }
      await screen.catchUp()
      #expect(try screen.shows("No Downloads"))

      center.add(download(profile: "mine"))
      await screen.catchUp()
      #expect(screen.rowPoints.count == 1)
      #expect(try !screen.shows("No Downloads"))
    }

    @Test("Cancel stops a running download, and a refusal is shown on its row")
    func cancel() async throws {
      SystemSideEffects.install()
      let center = BrowserDownloadCenter()
      let settings = BrowserDownloadSettings(defaults: try isolatedDefaults())
      var cancels = 0
      center.add(
        download(total: 10, received: 4) { () throws(BrowserError) in
          cancels += 1
          throw .downloadFailed("refused")
        })
      let screen = OffscreenWindow(
        BrowserDownloadsView(center: center, settings: settings), width: 420, height: 320)
      defer { screen.close() }
      await screen.catchUp()
      #expect(screen.progressBars.contains { abs($0.doubleValue - 0.4) < 0.01 })
      let cancel = try #require(screen.controlFrames.first)
      try screen.click(CGPoint(x: cancel.midX, y: cancel.midY))
      await screen.catchUp()
      #expect(cancels == 1)
    }

    @Test("a finished download reveals its file in Finder; a stopped one offers nothing")
    func reveal() async throws {
      SystemSideEffects.install()
      SystemSideEffects.reset()
      let center = BrowserDownloadCenter()
      let settings = BrowserDownloadSettings(defaults: try isolatedDefaults())
      let finished = download(received: 3, state: .complete)
      center.add(finished)
      let screen = OffscreenWindow(
        BrowserDownloadsView(center: center, settings: settings), width: 420, height: 320)
      defer { screen.close() }
      await screen.catchUp()
      let show = try #require(screen.controlFrames.first)
      try screen.click(CGPoint(x: show.midX, y: show.midY))
      #expect(SystemSideEffects.record.revealedURLs == [finished.destination])

      let stopped = screen.controlFrames.count
      finished.state = .cancelled
      await screen.catchUp()
      #expect(screen.controlFrames.count == stopped - 1)
    }

    @Test("the folder can be changed by panel, and asking first can be turned on")
    func settings() async throws {
      SystemSideEffects.install()
      SystemSideEffects.reset()
      let settings = BrowserDownloadSettings(defaults: try isolatedDefaults())
      settings.askBeforeDownload = false
      let original = settings.directory
      let screen = OffscreenWindow(
        BrowserDownloadSettingsView(settings: settings), width: 420, height: 90)
      defer { screen.close() }
      await screen.catchUp()
      #expect(try screen.shows("Save to \(original.lastPathComponent)"))

      let change = try #require(screen.controlFrames.first)
      try screen.click(CGPoint(x: change.midX, y: change.midY))
      #expect(SystemSideEffects.record.panelCount == 1)
      #expect(settings.directory == original)

      let chosen = try temporaryDirectory()
      SystemSideEffects.answer(panel: .OK, panelURL: chosen)
      defer { SystemSideEffects.reset() }
      try screen.click(CGPoint(x: change.midX, y: change.midY))
      #expect(settings.directory == chosen)

      let ask = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: ask.midX, y: ask.midY))
      #expect(settings.askBeforeDownload)
    }

    @Test("the toolbar's button opens the list in a popover that can't be seen")
    func popovers() async throws {
      let fixture = try TabFixture()
      let screen = OffscreenWindow(
        BrowserTabDownloadsButton(
          presenter: fixture.environment.presenter,
          profileIdentifier: fixture.model.browserProfile.identifier), width: 200, height: 60)
      defer { screen.close() }
      fixture.environment.presenter.downloadCenter.add(
        download(profile: fixture.model.browserProfile.identifier))
      await screen.catchUp()
      let windowsBefore = NSApp.windows.count
      try screen.clickControl(at: 0)
      await screen.catchUp()
      #expect(NSApp.windows.count > windowsBefore)
      #expect(screen.nothingOnScreen)
      try screen.clickControl(at: 0)
      await screen.catchUp()

      let plain = OffscreenWindow(
        BrowserDownloadsButton(presenter: fixture.environment.presenter), width: 200, height: 60)
      defer { plain.close() }
      await plain.catchUp()
      try plain.clickControl(at: 0)
      await plain.catchUp()
      #expect(plain.nothingOnScreen)
    }
  }

  @MainActor
  @Suite("Clear data and site settings, off screen", .serialized)
  struct DataViewTests {
    @Test("Clear Data clears what's ticked for the chosen range and closes")
    func clearData() async throws {
      let fixture = try TabFixture()
      let profileID = fixture.model.profileID
      let history = fixture.environment.history(for: profileID)
      history.recordVisit(url: try testURL("https://a.example/"), title: "Old")
      let screen = OffscreenWindow(
        BrowserClearDataView(environment: fixture.environment, profileID: profileID), width: 460,
        height: 420)
      defer { screen.close() }
      await screen.catchUp()
      #expect(try screen.shows("Clear Browsing Data"))
      // Picker, six toggles, Cancel, Clear Data.
      #expect(screen.controlFrames.count == 9)

      // Toggling the cookies, cache and storage off leaves history and the two extras' opposite.
      for index in 2...4 { try screen.clickControl(at: index) }
      try screen.clickControl(at: 5)
      try screen.clickControl(at: 6)
      try screen.clickControl(at: 8)
      await screen.letSheetSettle()

      #expect(history.visits.isEmpty)
      #expect(fixture.provider.engines[.system]?.removed.isEmpty ?? true)
    }

    @Test("with nothing ticked Clear Data does nothing; an engine failure stays on the sheet")
    func clearDataFailure() async throws {
      SystemSideEffects.install()
      let defaults = try isolatedDefaults()
      let provider = FailingDataProvider()
      let environment = BrowserEnvironment(
        directory: nil, provider: provider,
        preferences: BrowserPreferences(defaults: defaults, defaultEngine: .system),
        defaults: defaults)
      let screen = OffscreenWindow(
        BrowserClearDataView(
          environment: environment, profileID: environment.profiles.defaultProfileID), width: 460,
        height: 420)
      defer { screen.close() }
      await screen.catchUp()
      try screen.clickControl(at: 8)
      await screen.letSheetSettle()
      #expect(try screen.shows("no engine"))
    }

    @Test("each time range looks back the right distance")
    func ranges() throws {
      typealias Range = BrowserClearDataView.Range
      #expect(Range.allTime.since == nil)
      let hour = try #require(Range.lastHour.since)
      let day = try #require(Range.lastDay.since)
      let week = try #require(Range.lastWeek.since)
      #expect(abs(hour.timeIntervalSinceNow + 3_600) < 5)
      #expect(abs(day.timeIntervalSinceNow + 86_400) < 5)
      #expect(abs(week.timeIntervalSinceNow + 7 * 86_400) < 5)
      #expect(Range.lastHour.id == "Last hour")
    }

    @Test("a remembered permission is listed, says what it is, and can be forgotten")
    func siteSettings() async throws {
      let fixture = try TabFixture()
      let store = fixture.environment.presenter.permissionStore
      let profile = fixture.model.browserProfile
      store.record(.allow, for: .camera, origin: "https://a.example", profile: profile)
      store.record(.deny, for: .microphone, origin: "https://b.example", profile: profile)
      let screen = OffscreenWindow(
        BrowserSiteSettingsView(store: store, profile: profile), width: 520, height: 340)
      defer { screen.close() }
      await screen.catchUp()
      #expect(screen.rowPoints.count == 2)

      try screen.clickControl(at: 0)
      await screen.catchUp()
      #expect(store.decisions(for: profile).count == 1)
      try screen.clickControl(at: 0)
      await screen.catchUp()
      #expect(store.decisions(for: profile).isEmpty)
      #expect(try screen.shows("No Remembered Permissions"))
    }

    @Test("settings choose a search engine, a custom template and the bookmarks bar")
    func settings() async throws {
      let fixture = try TabFixture()
      let settings = fixture.environment.settings
      let screen = OffscreenWindow(
        Form { BrowserSettingsView(environment: fixture.environment) }, width: 520, height: 360)
      defer { screen.close() }
      await screen.catchUp()

      try screen.choose("Custom", in: screen.popupMenu())
      await screen.catchUp()
      #expect(settings.searchEngineID == "custom")
      #expect(try screen.shows("Use an http(s) URL with one %s"))

      try screen.focusField()
      try screen.type("https://s.example/?q=%s")
      await screen.catchUp()
      #expect(settings.customSearchTemplate == "https://s.example/?q=%s")
      #expect(try !screen.shows("Use an http(s) URL with one %s"))

      let before = settings.showsBookmarksBar
      let frames = screen.controlFrames
      // Engine picker, template field, bar toggle, Manage….
      try screen.clickControl(at: frames.count - 2)
      #expect(settings.showsBookmarksBar != before)

      try screen.clickDrawnButton(at: 0)
      await screen.letSheetSettle()
      #expect(screen.hasSheet)
      #expect(screen.nothingOnScreen)
    }
  }

  @MainActor
  @Suite("Browser menu commands", .serialized)
  struct TabCommandViewTests {
    private func menu(_ fixture: TabFixture?, sheet: Binding<BrowserTabSheet?>?, find: Bool = true)
      -> some View
    {
      Menu("Browser") {
        BrowserTabCommandItems(tab: fixture?.model, sheet: sheet, includesFindAndZoom: find)
      }
      .menuStyle(.borderlessButton)
    }

    @Test("the Browser menu can go in an app's menu bar")
    func menuBarCommands() {
      let commands = BrowserTabCommands(includesFindAndZoom: false)
      #expect(String(describing: type(of: commands.body)).contains("CommandMenu"))
    }

    @Test("every item reaches the focused tab")
    func items() async throws {
      let fixture = try TabFixture()
      fixture.environment.onOpenTab = { _, _ in }
      let tab = try fixture.tab
      let model = fixture.model
      let screen = OffscreenWindow(menu(fixture, sheet: nil), width: 200, height: 40)
      defer { screen.close() }
      await screen.catchUp()
      let items = try screen.popupMenu()

      let focus = model.omniboxFocusRequest
      try screen.choose("Open Location", in: items)
      #expect(model.omniboxFocusRequest == focus + 1)
      try screen.choose("Reload Page", in: items)
      #expect(tab.commands.last == "reload")
      try screen.choose("Reload Ignoring Cache", in: items)
      #expect(tab.commands.last == "hardReload")
      try screen.choose("Find…", in: items)
      #expect(model.find.isVisible)
      model.find.query = "cat"
      try screen.choose("Find Next", in: items)
      await screen.catchUp()
      #expect(tab.commands.last == "find cat forward false")
      try screen.choose("Find Previous", in: items)
      await screen.catchUp()
      #expect(tab.commands.last == "find cat backward false")
      try screen.choose("Zoom In", in: items)
      #expect(tab.state.zoomFactor > 1)
      try screen.choose("Zoom Out", in: items)
      #expect(tab.state.zoomFactor == 1)
      try screen.choose("Zoom In", in: items)
      try screen.choose("Actual Size", in: items)
      #expect(tab.state.zoomFactor == 1)
      try screen.choose("Mute Tab", in: items)
      #expect(tab.state.isMuted)
      try screen.choose("Bookmark This Page", in: items)
      #expect(model.isBookmarked)
      try screen.choose("Print…", in: items)
      await screen.catchUp()
      #expect(tab.commands.contains("print"))
      try screen.choose("View Source", in: items)
      await screen.catchUp()
      #expect(tab.commands.contains("viewSource"))
      try screen.choose("Developer Tools", in: items)
      #expect(tab.commands.last == "devtools")
    }

    @Test("the sheet items ask the focused tab to show them")
    func sheetItems() async throws {
      let fixture = try TabFixture()
      let recorder = SheetRecorder()
      let screen = OffscreenWindow(
        menu(fixture, sheet: Binding(get: { recorder.value }, set: { recorder.value = $0 })),
        width: 200, height: 40)
      defer { screen.close() }
      await screen.catchUp()
      let items = try screen.popupMenu()
      for (title, target) in [
        ("Show History", BrowserTabSheet.history), ("Show Bookmarks", .bookmarks),
        ("Clear Browsing Data…", .clearData),
      ] {
        try screen.choose(title, in: items)
        #expect(recorder.value == target)
      }
    }

    @Test("an app that routes Find and Zoom itself doesn't get them twice")
    func withoutFindAndZoom() async throws {
      let fixture = try TabFixture()
      let screen = OffscreenWindow(
        menu(fixture, sheet: nil, find: false), width: 200, height: 40)
      defer { screen.close() }
      await screen.catchUp()
      let items = try screen.popupMenu()
      #expect(!items.items.contains { $0.title == "Find…" })
      #expect(!items.items.contains { $0.title == "Zoom In" })
      #expect(items.items.contains { $0.title == "Reload Page" })
    }

    @Test("with no browser tab focused every item is off")
    func noTab() async throws {
      SystemSideEffects.install()
      let screen = OffscreenWindow(menu(nil, sheet: nil), width: 200, height: 40)
      defer { screen.close() }
      await screen.catchUp()
      let items = try screen.popupMenu()
      #expect(items.items.filter { !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled })
    }
  }
#endif
