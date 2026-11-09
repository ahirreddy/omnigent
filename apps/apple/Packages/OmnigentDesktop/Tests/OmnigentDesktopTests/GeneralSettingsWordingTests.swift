import Foundation
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentDesktop

@MainActor
@Suite("General settings wording", .serialized)
struct GeneralSettingsWordingTests {
  @Test("the new-window setting says what it does, and starts on the server picker")
  func newWindowSetting() throws {
    let suite = "GeneralSettingsWordingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = DesktopPreferences(defaults: defaults)
    #expect(preferences.defaultServerURL == nil)

    let screen = OffscreenWindow(
      GeneralSettingsTab(
        preferences: preferences, managed: ManagedPreferences(domains: []), recentServers: [],
        browserSettings: EmptyView()),
      width: 500, height: 300)
    defer { screen.close() }
    screen.settle()
    #expect(try screen.shows("New windows open on"))
    #expect(try screen.shows("Server picker"))
    #expect(try !screen.shows("Connect screen"))
  }
}
