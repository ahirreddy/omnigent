import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

private let address = "http://127.0.0.1:6767"
private let catalog = #"""
  {"object":"list","data":[{"object":"extension","id":"example.hello-page",
   "display_name":"Hello Extension","distribution":"example-hello","version":"1.0.0",
   "extension_api":1,"status":"enabled","permissions":["navigation"],
   "pages":[{"id":"example.hello-page.home","title":"Hello Extension","route":"hello","view":"hello"}],
   "primary_navigation":[{"id":"example.hello-page.nav","label":"Hello Extension",
     "page":"example.hello-page.home","icon":"puzzle","order":10,"when":null}],
   "browser":{"declared":true,"has_styles":false,"digest":"abc123",
     "script_url":"/v1/extensions/example.hello-page/assets/abc123/extension.js","style_url":null}}]}
  """#

/// The server's extensions are read with the pages it offers, on each connect.
@MainActor
@Suite("Extensions store", .timeLimit(.minutes(1)))
struct ExtensionsStoreTests {
  @Test("Each connect reads the extensions; their entries and pages resolve by route")
  func readOnConnect() async throws {
    let server = RouteServer()
    server.route("/v1/info", .json(#"{"single_user":true,"accounts_enabled":false}"#))
    server.route("/v1/extensions", .json(catalog))
    let store = try disconnectedStore(server)
    await store.connect(serverURL: address)
    let extensions = try #require(store.extensions)
    try await eventually("the catalog") { !extensions.extensions.isEmpty }
    #expect(!extensions.isLoading)
    #expect(extensions.loadError == nil)
    let entry = try #require(extensions.navigationEntries.first)
    #expect(entry.extensionId == "example.hello-page")
    #expect(entry.page.route == "hello")
    #expect(
      extensions.page(extensionID: "example.hello-page", route: "hello")?.1.title
        == "Hello Extension")
    #expect(extensions.page(extensionID: "example.hello-page", route: "other") == nil)
  }

  @Test("A failed read leaves no extensions and keeps why")
  func failedRead() async throws {
    let server = RouteServer()
    server.route("/v1/info", .json(#"{"single_user":true,"accounts_enabled":false}"#))
    server.route("/v1/extensions", .json(#"{"object":"list","data":[{"id":"nodot"}]}"#))
    let store = try disconnectedStore(server)
    await store.connect(serverURL: address)
    let extensions = try #require(store.extensions)
    try await eventually("the failed read") { extensions.loadError != nil }
    #expect(extensions.extensions.isEmpty)
    #expect(!extensions.isLoading)
  }
}
