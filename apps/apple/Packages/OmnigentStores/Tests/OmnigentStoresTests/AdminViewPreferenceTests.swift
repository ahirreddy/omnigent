import Foundation
import Testing

@testable import OmnigentStores

/// The admin view's per-origin choice, as the web's cookie keeps it.
@Suite("Admin view preference")
struct AdminViewPreferenceTests {
  @Test("on unless turned off, per origin, whatever the mount or path")
  func perOrigin() throws {
    let defaults = try #require(UserDefaults(suiteName: "admin-view-\(UUID().uuidString)"))
    let server = "https://agents.example.com/omnigent"
    #expect(AdminViewPreference.isOn(for: server, defaults: defaults))
    AdminViewPreference.set(false, for: server, defaults: defaults)
    #expect(!AdminViewPreference.isOn(for: "HTTPS://Agents.example.com/", defaults: defaults))
    #expect(AdminViewPreference.isOn(for: "https://agents.example.com:8443", defaults: defaults))
    #expect(AdminViewPreference.isOn(for: "https://other.example.com", defaults: defaults))
    AdminViewPreference.set(true, for: server, defaults: defaults)
    #expect(AdminViewPreference.isOn(for: server, defaults: defaults))
    #expect(AdminViewPreference.isOn(for: "not a url", defaults: defaults))
  }
}
