#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentDesktop

  /// Settings > Notifications: what to notify about, the sound and the permission.
  @MainActor
  @Suite("Notification settings", .serialized)
  struct NotificationSettingsTests {
    init() { DesktopSideEffects.reset() }

    private func notifications(
      _ fixture: DesktopFixture, isAvailable: Bool = false
    ) -> OffscreenWindow<NotificationSettingsTab> {
      OffscreenWindow(
        NotificationSettingsTab(
          preferences: fixture.desktop.preferences, notifications: fixture.desktop.notifications,
          isAvailable: isAvailable),
        width: 580, height: 640)
    }

    /// The tab's switches: turn finished, input, runner offline, then sound.
    private func switches<Content: View>(_ screen: OffscreenWindow<Content>) -> [CGRect] {
      screen.controlFrames.filter { $0.width < 40 && $0.height < 20 }
    }

    @Test("each notification switch changes its own preference")
    func notificationSwitches() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let preferences = fixture.desktop.preferences
      let screen = notifications(fixture)
      defer { screen.close() }
      await flush(screen)
      #expect(try screen.allText().contains("Unavailable outside the app"))
      let frames = switches(screen)
      try #require(frames.count == 4, "\(screen.controlFrames)")
      try screen.click(frames[0])
      #expect(!preferences.notifyTurnEnded)
      #expect(preferences.notifyElicitations)
      try screen.click(frames[1])
      #expect(!preferences.notifyElicitations)
      try screen.click(frames[2])
      #expect(!preferences.notifyRunnerOffline)
      #expect(!preferences.soundEnabled)
      try screen.click(frames[3])
      #expect(preferences.soundEnabled)
    }

    @Test("the sound menu waits for Play sound, then choosing one previews it")
    func soundChoice() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let preferences = fixture.desktop.preferences
      preferences.soundEnabled = true
      let screen = notifications(fixture)
      defer { screen.close() }
      await flush(screen)
      let picker = try #require(screen.controlFrames.last)
      let menu = try screen.openMenu(CGPoint(x: picker.midX, y: picker.midY))
      #expect(screen.titles(menu).contains("Basso"))
      try screen.choose("Basso", in: menu)
      await flush(screen)
      #expect(preferences.soundName == "Basso")
      #expect(DesktopSideEffects.state.playedSounds == ["Basso"])
    }

    @Test("a sound that won't play says so")
    func soundFails() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      fixture.desktop.preferences.soundEnabled = true
      DesktopSideEffects.state.soundsPlay = false
      let screen = notifications(fixture)
      defer { screen.close() }
      await flush(screen)
      let picker = try #require(screen.controlFrames.last)
      let menu = try screen.openMenu(CGPoint(x: picker.midX, y: picker.midY))
      try screen.choose("Tink", in: menu)
      await flush(screen)
      #expect(try screen.allText().contains("Could not play Tink."))
    }

    @Test("a saved sound that's gone falls back to the default")
    func missingSound() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      fixture.desktop.preferences.soundName = "Not A Sound"
      let screen = notifications(fixture)
      defer { screen.close() }
      await flush(screen)
      #expect(fixture.desktop.preferences.soundName == SystemSounds.defaultName)
    }

    @Test(
      "the permission line follows what macOS says",
      arguments: [
        (DesktopNotificationCenter.Authorization.unknown, "Checking\u{2026}"),
        (.notDetermined, "Not requested"),
        (.denied, "Off in System Settings"),
        (.authorized, "Allowed"),
        (.provisional, "Delivered quietly"),
      ])
    func permissionLabels(
      authorization: DesktopNotificationCenter.Authorization, label: String
    ) throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      fixture.desktop.notifications.authorization = authorization
      let screen = notifications(fixture, isAvailable: true)
      defer { screen.close() }
      #expect(try screen.allText().contains(label))
    }

    @Test("Allow Notifications shows why the request failed")
    func allowFails() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      fixture.desktop.notifications.authorization = .notDetermined
      let screen = notifications(fixture, isAvailable: true)
      defer { screen.close() }
      await flush(screen)
      // This process has no bundle, so reading the permission failed on its own.
      #expect(try screen.allText().contains("Could not read notification permission"))
      let allow = try #require(screen.controlFrames.first)
      try screen.click(allow)
      #expect(
        await settle(screen) {
          (try? screen.allText().contains("Could not request notification permission")) == true
        })
    }

    @Test("Open Notification Settings goes to System Settings")
    func openSettings() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      fixture.desktop.notifications.authorization = .denied
      let screen = notifications(fixture, isAvailable: true)
      defer { screen.close() }
      await flush(screen)
      let open = try #require(screen.controlFrames.first)
      try screen.click(open)
      let opened = try #require(SystemSideEffects.record.openedURLs.first)
      #expect(opened.scheme == "x-apple.systempreferences")
      #expect(opened.path().contains("Notifications"))
    }
  }

  /// Settings > Advanced: managed values and troubleshooting.
  @MainActor
  @Suite("Advanced settings", .serialized)
  struct AdvancedSettingsTests {
    init() { DesktopSideEffects.reset() }

    private func managed(
      _ values: [String: Any], forced: Bool = false, domains: [String] = ["ai.omnigent.mac"]
    ) -> ManagedPreferences {
      ManagedPreferences(
        domains: domains, readValue: { key, domain in domain == domains[0] ? values[key] : nil },
        readForced: { _, _ in forced })
    }

    private func advanced(
      _ managed: ManagedPreferences, export: (() -> Void)? = nil
    ) -> OffscreenWindow<AdvancedSettingsTab> {
      OffscreenWindow(
        AdvancedSettingsTab(managed: managed, exportDiagnostics: export), width: 580, height: 560)
    }

    @Test("Advanced lists the organization's servers and where they came from")
    func advancedServers() async throws {
      let screen = advanced(
        managed(["serverUrls": ["https://corp.test"], "databricksInternalFeaturesEnabled": true]))
      defer { screen.close() }
      #expect(await settle(screen) { (try? screen.allText().contains("corp.test")) == true })
      let text = try screen.allText()
      #expect(text.contains("https://corp.test"))
      #expect(text.contains("ai.omnigent.mac"))
      #expect(!text.contains("(profile)"))
      #expect(text.contains("On"))
      #expect(text.contains("Read from the ai.omnigent.mac preference domain."))
    }

    @Test("a forced list is marked as a profile, and two domains are both named")
    func advancedForced() async throws {
      let screen = advanced(
        managed(
          ["serverUrls": ["https://corp.test"]], forced: true,
          domains: ["ai.omnigent.mac", "ai.omnigent.desktop"]))
      defer { screen.close() }
      #expect(await settle(screen) { (try? screen.allText().contains("(profile)")) == true })
      #expect(try screen.allText().contains("ai.omnigent.mac and ai.omnigent.desktop"))
    }

    @Test("bad managed values show as ignored, and a bad flag reads as off with why")
    func advancedFailures() async throws {
      let screen = advanced(
        managed(["serverUrls": 5, "databricksInternalFeaturesEnabled": "yes"]))
      defer { screen.close() }
      #expect(await settle(screen) { (try? screen.allText().contains("Ignored:")) == true })
      let text = try screen.allText()
      #expect(text.contains("serverUrls is not a list"))
      #expect(text.contains("databricksInternalFeaturesEnabled is not a boolean"))
    }

    @Test("every managed preference problem reads as a line")
    func summaries() {
      #expect(
        ManagedPreferencesError.tooManyServers(domain: "d", count: 11).localizedSummary
          == "d serverUrls has 11 entries (at most 10)")
      #expect(
        ManagedPreferencesError.invalidServer(domain: "d", index: 0, reason: "is empty")
          .localizedSummary == "d serverUrls entry 1 is empty")
    }

    @Test("Reset Window Position forgets the saved frame, and Export Diagnostics runs")
    func troubleshooting() async throws {
      var exported = 0
      let screen = advanced(managed([:], domains: []), export: { exported += 1 })
      defer { screen.close() }
      await flush(screen)
      let key = "NSWindow Frame \(ServerWindowMetrics.frameAutosaveName)"
      UserDefaults.standard.set("0 0 100 100 0 0 800 800", forKey: key)
      try screen.click(screen.controlFrames[0])
      #expect(UserDefaults.standard.string(forKey: key) == nil)
      try screen.click(screen.controlFrames[1])
      #expect(exported == 1)
      #expect(try screen.allText().contains("No managed preference domain is read."))
      #expect(try screen.allText().contains("No organization servers are configured."))
    }
  }
#endif
