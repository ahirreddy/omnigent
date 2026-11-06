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
}
