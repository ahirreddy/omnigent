import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import Testing
import UIKit

@testable import Omnigent

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
    #expect(discovery.serverName == "Local Omnigent")
    #expect(discovery.authMode == .unauthenticated)
  }
}

/// Dev builds are signed by teams that the HTTPS redirect's associated domain doesn't list, so
/// Debug signs in to Databricks through the loopback redirect; Release keeps the HTTPS one.
struct DatabricksRedirectTests {
  @Test func redirectMatchesTheBuildConfiguration() {
    let info = Bundle.main
    #expect(info.object(forInfoDictionaryKey: "DatabricksOAuthClientID") as? String == "omnigent")
    let redirect = info.object(forInfoDictionaryKey: "DatabricksOAuthRedirectURL") as? String
    #if DEBUG
      #expect(redirect == "http://localhost")
    #else
      #expect(redirect == "https://login.databricks.com/mobile-redirect")
    #endif
  }
}

@MainActor
struct WindowTintTests {
  /// Built on the main actor as the window does; SwiftUI's async renderer resolves the tint off
  /// the main thread, where a provider isolated to the main actor traps.
  @Test func adaptiveColorResolvesOffTheMainThread() async {
    let color = UIColor.adaptive(light: .white, dark: .black)
    let (light, dark) = await Task.detached {
      (
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)),
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
      )
    }.value
    #expect(light == .white)
    #expect(dark == .black)
  }

  /// Opening the share sheet encodes the host's traits, tint included, for its scene on a
  /// background queue; encoding a dynamic color calls its provider there.
  @Test func adaptiveColorEncodesOffTheMainThread() async throws {
    let color = UIColor.adaptive(light: .white, dark: .black)
    let data = try await Task.detached {
      try NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
    }.value
    #expect(!data.isEmpty)
  }
}
