#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentDesktop

  /// Settings' General tab and the window that holds every tab.
  @MainActor
  @Suite("Settings tabs", .serialized)
  struct GeneralSettingsTests {
    init() { DesktopSideEffects.reset() }

    private func managed(
      _ values: [String: Any], forced: Bool = false, domains: [String] = ["ai.omnigent.mac"]
    ) -> ManagedPreferences {
      ManagedPreferences(
        domains: domains, readValue: { key, domain in domain == domains[0] ? values[key] : nil },
        readForced: { _, _ in forced })
    }

    private func general(
      _ fixture: DesktopFixture, managed: ManagedPreferences? = nil, recents: [URL] = []
    ) -> OffscreenWindow<GeneralSettingsTab<EmptyView>> {
      OffscreenWindow(
        GeneralSettingsTab(
          preferences: fixture.desktop.preferences,
          managed: managed ?? fixture.desktop.managedPreferences, recentServers: recents,
          browserSettings: EmptyView()),
        width: 580, height: 500)
    }

    private func pickerMenu<Content: View>(_ screen: OffscreenWindow<Content>) throws -> NSMenu {
      let picker = try #require(screen.controlFrames.first)
      return try screen.openMenu(CGPoint(x: picker.midX, y: picker.midY))
    }

    @Test("new windows default to the connect screen and can pick a recent server")
    func recentDefault() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let recent = try url("https://recent.test")
      let screen = general(fixture, recents: [recent])
      defer { screen.close() }
      await flush(screen)
      let menu = try pickerMenu(screen)
      #expect(screen.titles(menu).contains("Connect screen"))
      #expect(screen.titles(menu).contains("recent.test"))
      try screen.choose("recent.test", in: menu)
      await flush(screen)
      #expect(fixture.desktop.preferences.defaultServerURL == recent)
      try screen.choose("Connect screen", in: try pickerMenu(screen))
      await flush(screen)
      #expect(fixture.desktop.preferences.defaultServerURL == nil)
    }

    @Test("organization servers lead the list and aren't repeated as recents")
    func organizationServers() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let preferences = managed(["serverUrls": ["https://corp.test"]])
      let screen = general(
        fixture, managed: preferences,
        recents: [try url("https://corp.test/"), try url("https://other.test")])
      defer { screen.close() }
      await flush(screen)
      let titles = screen.titles(try pickerMenu(screen))
      #expect(titles.contains("Provided by your organization"))
      #expect(titles.contains("corp.test"))
      #expect(titles.filter { $0 == "corp.test" }.count == 1)
      #expect(titles.contains("other.test"))
    }

    @Test("a saved default that's no longer listed still shows as itself")
    func unlistedDefault() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      fixture.desktop.preferences.defaultServerURL = try url("https://gone.test/x")
      let screen = general(fixture)
      defer { screen.close() }
      await flush(screen)
      #expect(screen.titles(try pickerMenu(screen)).contains("https://gone.test/x"))
    }

    @Test("a bad organization list is ignored, and the tab says why")
    func badOrganizationList() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let screen = general(fixture, managed: managed(["serverUrls": "not a list"]))
      defer { screen.close() }
      #expect(await settle(screen) { (try? screen.allText().contains("was ignored")) == true })
      #expect(try screen.allText().contains("ai.omnigent.mac serverUrls is not a list"))
    }

    @Test("the Settings window opens on General and each tab shows its form")
    func window() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let extra = SettingsTabItem("Extra", systemImage: "star", isWide: true) {
        Text(verbatim: "Extra content")
      }
      #expect(extra.id == "Extra")
      let screen = OffscreenWindow(
        OmnigentSettingsView(desktop: fixture.desktop, extraTabs: [extra]) {
          Text(verbatim: "Browser section")
        },
        width: 700, height: 800)
      defer { screen.close() }
      await flush(screen)
      #expect(try screen.allText().contains("Browser section"))
      let tabs = try #require(screen.allViews.compactMap { $0 as? NSSegmentedControl }.first)
      let frame = tabs.convert(tabs.bounds, to: screen.host)
      let width = frame.width / CGFloat(tabs.segmentCount)
      let expected = [
        (1, "A turn finishes"), (2, "Extra content"), (3, "Data directory"),
        (4, "Reset Window Position"),
      ]
      for (segment, text) in expected {
        try screen.click(
          CGPoint(x: frame.minX + width * (CGFloat(segment) + 0.5), y: frame.midY))
        await flush(screen)
        #expect(try screen.allText().contains(text), "\(text)")
      }
    }

    @Test("Settings can be opened at a tab from outside")
    func selection() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      var tab = SettingsTabID.advanced
      let binding = Binding(get: { tab }, set: { tab = $0 })
      let screen = OffscreenWindow(
        OmnigentSettingsView(desktop: fixture.desktop, selection: binding) { EmptyView() },
        width: 700, height: 800)
      defer { screen.close() }
      await flush(screen)
      #expect(try screen.allText().contains("Reset Window Position"))
      let plain = OffscreenWindow(
        OmnigentSettingsView(desktop: fixture.desktop), width: 700, height: 800)
      defer { plain.close() }
      await flush(plain)
      #expect(try plain.allText().contains("Open new windows on"))
    }
  }
#endif
