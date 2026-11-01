import Foundation
import Testing

@testable import OmnigentDesktop

@Suite("System wake monitor")
@MainActor
struct SystemWakeMonitorTests {
  @Test("maps notifications to triggers in order and finishes on stop")
  func triggers() async {
    let center = NotificationCenter()
    let wake = Notification.Name("test.wake")
    let unlock = Notification.Name("test.unlock")
    let monitor = SystemWakeMonitor(sources: [
      .init(center: center, name: wake, trigger: .systemWake),
      .init(center: center, name: unlock, trigger: .screenUnlock),
    ])
    center.post(name: wake, object: nil)
    center.post(name: unlock, object: nil)
    center.post(name: Notification.Name("test.unrelated"), object: nil)
    monitor.stop()
    center.post(name: wake, object: nil)

    var received: [ReconnectTrigger] = []
    for await trigger in monitor.triggers {
      received.append(trigger)
    }
    #expect(received == [.systemWake, .screenUnlock])
  }

  @Test("the system sources cover wake, unlock and session switches")
  func systemSources() {
    let triggers = SystemWakeMonitor.Source.system.map(\.trigger)
    #expect(Set(triggers) == [.systemWake, .screenUnlock, .sessionActivated])
  }
}

@Suite("Desktop preferences")
@MainActor
struct DesktopPreferencesTests {
  private func freshDefaults() throws -> UserDefaults {
    let suite = "ai.omnigent.desktop.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
      throw FixtureError(description: "no defaults suite \(suite)")
    }
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  @Test("defaults: every notification on, sound off, WebKit, connect screen")
  func defaults() throws {
    let preferences = DesktopPreferences(defaults: try freshDefaults())
    #expect(preferences.defaultServerURL == nil)
    #expect(preferences.browserEngine == .webKit)
    #expect(preferences.notificationPreferences == NotificationPreferences())
    #expect(preferences.soundName == SystemSounds.defaultName)
  }

  @Test("changes persist")
  func persistence() throws {
    let defaults = try freshDefaults()
    let preferences = DesktopPreferences(defaults: defaults)
    preferences.defaultServerURL = try url("https://ws.example.com/ml/omnigents")
    preferences.browserEngine = .chromium
    preferences.notifyRunnerOffline = false
    preferences.soundEnabled = true
    preferences.soundName = "Ping"

    let reloaded = DesktopPreferences(defaults: defaults)
    #expect(reloaded.defaultServerURL == (try url("https://ws.example.com/ml/omnigents")))
    #expect(reloaded.browserEngine == .chromium)
    #expect(
      reloaded.notificationPreferences
        == NotificationPreferences(runnerOffline: false, soundEnabled: true))
    #expect(reloaded.soundName == "Ping")

    reloaded.defaultServerURL = nil
    #expect(DesktopPreferences(defaults: defaults).defaultServerURL == nil)
  }

  @Test("system sounds are listed")
  func systemSounds() throws {
    #expect(try SystemSounds.names().contains(SystemSounds.defaultName))
  }
}

@Suite("Server origin")
struct ServerOriginTests {
  @Test("normalizes URLs to WHATWG origins")
  func fromURL() throws {
    #expect(
      try ServerOrigin(url: url("HTTPS://Example.COM:443/a?b#c")).serialized
        == "https://example.com")
    #expect(
      try ServerOrigin(url: url("http://localhost:8000/")).serialized == "http://localhost:8000")
    #expect(try ServerOrigin(url: url("http://[::1]:8000")).serialized == "http://[::1]:8000")
    #expect(
      try ServerOrigin(url: url("https://ws.example.com:8443")).authority == "ws.example.com:8443")
  }

  @Test("rejects other schemes and credentials")
  func rejects() throws {
    let ftp = try url("ftp://example.com")
    #expect(throws: ServerOriginError.unsupportedScheme("ftp")) { try ServerOrigin(url: ftp) }
    let credentials = try url("https://user@example.com")
    #expect(throws: ServerOriginError.credentialsNotAllowed) { try ServerOrigin(url: credentials) }
    #expect(throws: ServerOriginError.invalidPort("70000")) {
      try ServerOrigin(scheme: .https, host: "example.com", port: 70_000)
    }
  }

  @Test("round-trips through its serialized form and Codable")
  func roundTrip() throws {
    let origin = try ServerOrigin(serialized: "https://example.com:8443/")
    #expect(origin.serialized == "https://example.com:8443")
    #expect(try ServerOrigin(serialized: origin.serialized) == origin)
    let data = try JSONEncoder().encode([origin])
    #expect(String(bytes: data, encoding: .utf8) == #"["https:\/\/example.com:8443"]"#)
    #expect(try JSONDecoder().decode([ServerOrigin].self, from: data) == [origin])
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode([ServerOrigin].self, from: Data(#"["ftp://x"]"#.utf8))
    }
  }

  @Test("loopback hosts infer http")
  func inferredScheme() {
    #expect(ServerOrigin.inferredScheme(forHost: "localhost") == .http)
    #expect(ServerOrigin.inferredScheme(forHost: "[::1]") == .http)
    #expect(ServerOrigin.inferredScheme(forHost: "127.0.0.2") == .https)
    #expect(ServerOrigin.inferredScheme(forHost: "example.com") == .https)
  }
}
