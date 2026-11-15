#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentDesktop

  /// The tabs, handed to the page that lays them out.
  @MainActor
  @Suite("Settings tabs for a page", .serialized)
  struct SettingsTabsPageTests {
    /// Lists the tabs as buttons over the shown tab's content, as a sidebar would.
    private struct ListedPage: View {
      let tabs: [SettingsTabItem]
      @Binding var selection: String
      let seen: Seen

      var body: some View {
        seen.tabs = tabs
        return VStack {
          ForEach(tabs) { tab in
            Button(tab.title) { selection = tab.id }
          }
          tabs.first { $0.id == selection }?.content
        }
      }
    }

    @MainActor
    private final class Seen {
      var tabs: [SettingsTabItem] = []
    }

    init() { DesktopSideEffects.reset() }

    @Test("a page gets every tab in order, with its icon, and shows the one that is clicked")
    func page() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let extra = SettingsTabItem("Extra", systemImage: "star", isWide: true) {
        Text(verbatim: "Extra content")
      }
      let seen = Seen()
      let screen = OffscreenWindow(
        OmnigentSettingsView(desktop: fixture.desktop, extraTabs: [extra]) {
          Text(verbatim: "Browser section")
        } page: { tabs, selection in
          ListedPage(tabs: tabs, selection: selection, seen: seen)
        },
        width: 700, height: 900)
      defer { screen.close() }
      await flush(screen)
      #expect(
        seen.tabs.map(\.title) == ["General", "Notifications", "Extra", "Local Server", "Advanced"])
      #expect(
        seen.tabs.map(\.systemImage)
          == ["gearshape", "bell.badge", "star", "server.rack", "gearshape.2"])
      #expect(seen.tabs.map(\.isWide) == [false, false, true, false, false])
      #expect(try screen.allText().contains("Browser section"), "it opens on General")

      let expected = [
        (1, "A turn finishes"), (2, "Extra content"), (3, "Data directory"),
        (4, "Reset Window Position"), (0, "New windows open on"),
      ]
      for (tab, text) in expected {
        // The tab buttons are the page's first controls, top to bottom.
        try screen.click(screen.controlFrames[tab])
        await flush(screen)
        #expect(try screen.allText().contains(text), "\(text)")
      }
    }

    @Test("a page can be opened at a tab from outside")
    func selection() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      var tab = SettingsTabID.advanced
      let binding = Binding(get: { tab }, set: { tab = $0 })
      let seen = Seen()
      let screen = OffscreenWindow(
        OmnigentSettingsView(desktop: fixture.desktop, selection: binding) {
          EmptyView()
        } page: { tabs, selection in
          ListedPage(tabs: tabs, selection: selection, seen: seen)
        },
        width: 700, height: 900)
      defer { screen.close() }
      await flush(screen)
      #expect(try screen.allText().contains("Reset Window Position"))
      try screen.click(screen.controlFrames[1])
      #expect(tab == SettingsTabID.notifications)
    }
  }
#endif
