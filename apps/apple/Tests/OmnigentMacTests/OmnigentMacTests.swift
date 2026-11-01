import Foundation
import OmnigentBrowser
import OmnigentCoreFFI
import OmnigentDesktop
import OmnigentStores
import OmnigentTestSupport
import Testing

// Shared by OmnigentMacTests (Developer ID host, OMNIGENT_CHROMIUM) and
// OmnigentMacAppStoreTests (App Store host). Each runs inside its own edition's app.
#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

@MainActor
struct AppConnectionTests {
  @Test func coreReportsVersion() {
    #expect(!coreVersion().isEmpty)
  }

  @Test func storeDiscoversThroughRustCore() async throws {
    let store = ConnectionStore(
      transport: FakeHttpTransport(routes: [
        "/.well-known/omnigent.json": .json(ManifestFixtures.localNoAuth)
      ])
    )

    await store.discover(serverURL: "http://127.0.0.1:6767")

    let discovery = try #require(store.discovery, "state: \(store.state)")
    #expect(store.isConnected)
    #expect(discovery.serverName == "Local Omnigent")
    #expect(discovery.authMode == .unauthenticated)
  }
}

@MainActor
struct EditionTests {
  @Test func editionMatchesBuild() {
    #if OMNIGENT_CHROMIUM
      #expect(AppEdition.current == .developerID)
    #else
      #expect(AppEdition.current == .appStore)
    #endif
  }

  @Test func offersOnlyTheEditionsEngines() throws {
    let provider = AppEdition.makeBrowserProvider()
    #if OMNIGENT_CHROMIUM
      #expect(provider.offeredEngines == [.chromium, .system])
      // The host app embeds CEF and its helpers, so Chromium is startable and the default.
      #expect(provider.availability(of: .chromium) == .available)
    #else
      #expect(provider.offeredEngines == [.system])
      #expect(!provider.availability(of: .chromium).isAvailable)
    #endif
    let defaults = try isolatedDefaults()
    defaults.set("chromium", forKey: BrowserPreferences.engineDefaultsKey)
    let preferences = BrowserPreferences(defaults: defaults, provider: provider)
    #if OMNIGENT_CHROMIUM
      #expect(preferences.defaultEngine == .chromium)
      #expect(preferences.engine == .chromium)
    #else
      #expect(preferences.defaultEngine == .system)
      // A stored Chromium choice never applies to a build without it.
      #expect(preferences.engine == .system)
    #endif
  }

  @Test func sandboxMatchesEdition() {
    let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    #if OMNIGENT_CHROMIUM
      #expect(!sandboxed)
    #else
      #expect(sandboxed)
    #endif
  }

  @Test func managedPreferenceDomains() throws {
    let bundleID = try #require(Bundle.main.bundleIdentifier)
    let domains = ManagedPreferences.domains(for: .main)
    #if OMNIGENT_CHROMIUM
      #expect(domains.first == bundleID)
      #expect(domains.contains("ai.omnigent.mac"))
      #expect(domains.contains("ai.omnigent.desktop"))
    #else
      #expect(bundleID.hasPrefix("ai.omnigent.mac.appstore"))
      #expect(domains == [bundleID])
    #endif
  }

  @Test func browserControllerUsesPerServerProfile() throws {
    let services = AppServices(desktop: DesktopController(), defaults: try isolatedDefaults())
    let serverURL = try #require(URL(string: "http://127.0.0.1:6767/workspace"))
    let controller = try services.makeBrowserController(serverURL: serverURL)
    #expect(controller.profile == .server("http://127.0.0.1:6767"))
    #expect(controller.profile.persistence == .persistent)
    #expect(controller.requestedURL == serverURL)
    #expect(controller.offeredEngines == services.browserProvider.offeredEngines)
  }

  @Test func browserControllerRejectsNonServerURLs() throws {
    let services = AppServices(desktop: DesktopController(), defaults: try isolatedDefaults())
    let fileURL = URL(fileURLWithPath: "/tmp")
    #expect(throws: ServerOriginError.self) {
      try services.makeBrowserController(serverURL: fileURL)
    }
  }
}

@MainActor
struct RecentServersTests {
  @Test func recordsMostRecentFirstWithoutDuplicates() throws {
    let defaults = try isolatedDefaults()
    let recents = RecentServers(defaults: defaults)
    let first = try #require(URL(string: "http://127.0.0.1:6767"))
    let second = try #require(URL(string: "https://omnigent.example.com"))
    recents.record(first)
    recents.record(second)
    recents.record(first)
    #expect(recents.urls == [first, second])
    #expect(RecentServers(defaults: defaults).urls == [first, second])
  }

  @Test func keepsAtMostTheLimit() throws {
    let recents = RecentServers(defaults: try isolatedDefaults())
    for port in 0..<(RecentServers.limit + 3) {
      recents.record(try #require(URL(string: "http://127.0.0.1:\(7000 + port)")))
    }
    #expect(recents.urls.count == RecentServers.limit)
    #expect(recents.urls.first?.port == 7000 + RecentServers.limit + 2)
  }

  @Test func reportsStoredEntriesThatAreNotURLs() throws {
    let defaults = try isolatedDefaults()
    defaults.set(["http://127.0.0.1:6767", "not a url"], forKey: RecentServers.defaultsKey)
    let recents = RecentServers(defaults: defaults)
    #expect(recents.urls.map(\.absoluteString) == ["http://127.0.0.1:6767"])
    #expect(recents.rejectedEntries == ["not a url"])
  }

  @Test func knownServersIncludeRecentsAndDefault() throws {
    let defaults = try isolatedDefaults()
    let desktop = DesktopController(defaults: defaults, managedDomains: [])
    let services = AppServices(desktop: desktop, defaults: defaults)
    let recent = try #require(URL(string: "http://127.0.0.1:6767"))
    let preferred = try #require(URL(string: "https://omnigent.example.com"))
    services.recentServers.record(recent)
    desktop.preferences.defaultServerURL = preferred
    #expect(services.knownServers() == [preferred, recent])
  }
}

private func isolatedDefaults() throws -> UserDefaults {
  let suite = "OmnigentMacTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  return defaults
}
