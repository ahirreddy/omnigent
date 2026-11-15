import AppKit
import OmnigentAppUI
import OmnigentDesktop
import OmnigentViewTesting
import SwiftUI
import Testing

#if OMNIGENT_CHROMIUM
  import OmnigentDesktopUpdate
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

#if DEBUG
  /// What a Settings test reads and clicks: the controls of the window's accessibility tree.
  extension OffscreenWindow {
    /// The accessibility names of the window's controls now.
    var controlNames: [String] {
      ChaosTargets.controls(in: window).map(\.name)
    }

    /// Whether a control's name holds `name` (an `#identifier`, or a label).
    func hasControl(_ name: String) -> Bool {
      controlNames.contains { $0.contains(name) }
    }

    /// Clicks the first control whose name holds `name`, with a real mouse down and up.
    func clickControl(named name: String) throws {
      let controls = ChaosTargets.controls(in: window)
      let control = try #require(
        controls.first { $0.name.contains(name) }, "\(name) in \(controls.map(\.name))")
      // The tree's points are the window's, from its bottom left; clicks are from the top left.
      try click(CGPoint(x: control.point.x, y: host.bounds.height - control.point.y))
    }

    /// Waits for `condition`, giving up the main actor so the window's tasks run.
    func waitFor(_ condition: () -> Bool, seconds: Double = 10) async throws -> Bool {
      let deadline = Date(timeIntervalSinceNow: seconds)
      while !condition(), Date() < deadline {
        settle(0.02)
        try await Task.sleep(for: .milliseconds(20))
      }
      return condition()
    }
  }

  /// The Settings page's content, with this edition's categories, offscreen.
  @MainActor
  @Suite(.enabled(if: HostedOffscreen.isAllowed), .serialized)
  struct AppSettingsViewTests {
    /// Each category, and a control only its pane has.
    nonisolated static let panes = [
      ("General", "#settings.submit-with-command-return"),
      ("Notifications", "#settings.notifications.play-sound"),
      ("Appearance", "#settings.terminal-theme"),
      ("Terminal", "#settings.terminal-font-family"),
      ("Phone", "#pairing.no-servers"),
      ("Servers", "#server-settings-picker"),
      ("Local Server", "#settings.local-server.menu-bar"),
      ("Advanced", "Reset Window Position"),
    ]

    private func settings(_ scratch: TestScratch, _ navigator: SettingsNavigator) -> some View {
      #if OMNIGENT_CHROMIUM
        AppSettingsView(
          services: scratch.services, updater: SparkleUpdater { _ in }, navigator: navigator)
      #else
        AppSettingsView(services: scratch.services, navigator: navigator)
      #endif
    }

    private func screen(_ scratch: TestScratch, _ navigator: SettingsNavigator)
      -> OffscreenWindow<some View>
    {
      ChaosTargets.buildAccessibilityTree()
      return OffscreenWindow(settings(scratch, navigator), width: 1000, height: 760)
    }

    /// A link opens Settings at a tab, and the category shows its own controls beside the
    /// sidebar's row for every category.
    @Test(arguments: panes)
    func aCategoryShowsItsOwnControls(category: String, control: String) async throws {
      let scratch = try TestScratch()
      defer { scratch.remove() }
      let navigator = SettingsNavigator()
      navigator.open(.tab(category))
      let screen = screen(scratch, navigator)
      defer { screen.close() }
      #expect(try await screen.waitFor { screen.hasControl(control) }, "\(screen.controlNames)")
      let found = screen.controlNames
      for (other, _) in Self.panes {
        #expect(found.contains { $0.contains("#settings-category-\(other)") }, "\(found)")
      }
      for (other, otherControl) in Self.panes where other != category {
        #expect(!found.contains { $0.contains(otherControl) }, "\(otherControl) on \(category)")
      }
    }

    /// From General, a click on each category's row shows that category's pane.
    @Test func aClickOnEachCategoryShowsItsPane() async throws {
      let scratch = try TestScratch()
      defer { scratch.remove() }
      let navigator = SettingsNavigator()
      let screen = screen(scratch, navigator)
      defer { screen.close() }
      #expect(try await screen.waitFor { screen.hasControl(Self.panes[0].1) })
      for (category, control) in Self.panes.reversed() {
        try screen.clickControl(named: "#settings-category-\(category)")
        #expect(navigator.tab == category)
        #expect(
          try await screen.waitFor { screen.hasControl(control) },
          "\(category): \(screen.controlNames)")
      }
    }

    /// Back leaves Settings, keeping the category for the next time.
    @Test func backLeavesSettings() async throws {
      let scratch = try TestScratch()
      defer { scratch.remove() }
      let navigator = SettingsNavigator()
      navigator.open(.tab("Terminal"))
      let screen = screen(scratch, navigator)
      defer { screen.close() }
      #expect(try await screen.waitFor { screen.hasControl("#settings-back") })
      try screen.clickControl(named: "#settings-back")
      #expect(!navigator.isPresented)
      #expect(navigator.tab == "Terminal")
    }

    /// A setting changed on a pane of the page is written to the preferences.
    @Test func aSettingChangesFromThePage() async throws {
      let scratch = try TestScratch()
      defer { scratch.remove() }
      let navigator = SettingsNavigator()
      navigator.open(.tab("Notifications"))
      let screen = screen(scratch, navigator)
      defer { screen.close() }
      let toggle = "#settings.notifications.play-sound"
      #expect(try await screen.waitFor { screen.hasControl(toggle) })
      let before = scratch.desktop.preferences.soundEnabled
      try screen.clickControl(named: toggle)
      #expect(scratch.desktop.preferences.soundEnabled == !before)
    }

    #if OMNIGENT_CHROMIUM
      /// General has Updates only in a window that was given the updater.
      @Test func updatesNeedTheUpdater() async throws {
        let scratch = try TestScratch()
        defer { scratch.remove() }
        ChaosTargets.buildAccessibilityTree()
        // Tall enough for all of General: Updates is its last section.
        let with = OffscreenWindow(
          settings(scratch, SettingsNavigator()), width: 1000, height: 2600)
        defer { with.close() }
        #expect(try await with.waitFor { with.hasControl("Check Now") }, "\(with.controlNames)")
        let without = OffscreenWindow(
          AppSettingsView(services: scratch.services, navigator: SettingsNavigator()),
          width: 1000, height: 2600)
        defer { without.close() }
        #expect(try await without.waitFor { without.hasControl(Self.panes[0].1) })
        #expect(!without.hasControl("Check Now"))
      }
    #endif
  }
#endif
