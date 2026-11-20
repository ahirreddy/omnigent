import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// An extension page's mount, as the web's `ExtensionViewHost` runs it: the bundle read (with one
/// catalog re-read for a stale digest), activation, and the requests answered through the
/// permissions the manifest grants.
@MainActor
@Suite("Extension page controller")
struct ExtensionPageControllerTests {
  private static let page = ExtensionPage(
    id: "example.hello-page.home", title: "Hello Extension", route: "hello", view: "hello")
  private static let script = "/v1/extensions/example.hello-page/assets/d1/extension.js"

  private static func extensionItem(
    permissions: [String] = ["navigation"], digest: String = "d1"
  ) -> Extension {
    Extension(
      id: "example.hello-page", displayName: "Hello", version: "1", permissions: permissions,
      pages: [page], navigation: [],
      bundle: ExtensionBundle(
        digest: digest,
        scriptUrl: "/v1/extensions/example.hello-page/assets/\(digest)/extension.js",
        styleUrl: nil))
  }

  /// The page's end of the channel: what the host sent, in order.
  private final class Port: ExtensionFramePort {
    var started: [String] = []
    var sent: [String] = []
    var closed = 0

    func start(_ message: String) -> Bool {
      started.append(message)
      return true
    }

    func send(_ message: String) { sent.append(message) }
    func close() { closed += 1 }

    func answers() -> [[String: Any]] {
      sent.compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
      }
    }
  }

  /// Host methods that answer at once, or wait until released.
  private final class Services: ExtensionHostServices {
    var calls: [String] = []
    var held: CheckedContinuation<Void, Never>?

    func perform(_ method: String, params: String?) async throws -> String {
      calls.append(method)
      if method == "navigation.openSession" {
        await withCheckedContinuation { held = $0 }
      }
      if method == "navigation.openPage" {
        throw ExtensionHostFault.Failed(code: "PermissionDenied", message: "Not yours")
      }
      return #"{"ok":true}"#
    }
  }

  private func controller(
    _ item: Extension, reads: @escaping (String) -> ExtensionAsset,
    refreshed: [Extension] = [], services: Services = Services(), port: Port,
    timeout: Duration = .seconds(10)
  ) -> ExtensionPageController {
    ExtensionPageController(
      extensionItem: item, page: Self.page,
      bundle: ExtensionBundleSource(
        read: { _, url in reads(url) }, refresh: { refreshed }),
      services: services, timeout: timeout, makeNonce: { "0a1b" }, port: port)
  }

  private func message(_ type: String, _ extra: String = "") -> String {
    #"{"source":"omnigent-extension","type":"\#(type)","extensionId":"example.hello-page","#
      + #""pageId":"example.hello-page.home","view":"hello","nonce":"0a1b","apiVersion":1"#
      + extra + "}"
  }

  private func settle() async {
    for _ in 0..<20 { await Task.yield() }
  }

  @Test("The page activates once its frame loads and it says it is ready")
  func activation() async {
    let port = Port()
    let page = controller(Self.extensionItem(), reads: { _ in .loaded(text: "run()") }, port: port)
    page.start()
    await settle()
    #expect(page.state.phase == .activating)
    #expect(page.state.hostPage?.contains("sandbox=\"allow-scripts\"") == true)
    page.channel.loaded()
    await settle()
    #expect(port.started.count == 1)
    let initMessage = port.started.first ?? ""
    #expect(initMessage.contains(#""capabilities":["navigation.openExternal""#))
    #expect(!initMessage.contains("storage.user"), "only granted methods")
    page.themeChanged(dark: true)
    page.receive(message("ready"))
    #expect(page.state.phase == .ready)
    #expect(port.sent.last?.contains(#""value":{"theme":"dark"}"#) == true)
    page.channel.reloaded()
    #expect(page.state.phase == .failed("Extension frame reloaded during activation"))
    #expect(port.closed == 1)
  }

  @Test("A stale digest reads the catalog once and loads the current bundle")
  func staleDigest() async {
    let port = Port()
    let page = controller(
      Self.extensionItem(digest: "old"),
      reads: { url in url.contains("/old/") ? .stale : .loaded(text: "run()") },
      refreshed: [Self.extensionItem(digest: "new")], port: port)
    page.start()
    await settle()
    #expect(page.state.phase == .activating)

    let gone = controller(
      Self.extensionItem(digest: "old"), reads: { _ in .stale }, refreshed: [], port: Port())
    gone.start()
    await settle()
    #expect(gone.state.phase == .failed("Extension script failed to load (404)"))
    #expect(gone.state.failureTitle == "Hello Extension could not start")
  }

  @Test("Requests run only granted methods, once per id, and answer in order")
  func requests() async throws {
    let port = Port()
    let services = Services()
    let page = controller(
      Self.extensionItem(), reads: { _ in .loaded(text: "run()") }, services: services, port: port
    )
    page.start()
    await settle()
    page.channel.loaded()
    page.receive(message("ready"))
    port.sent = []
    page.receive(message("request", #","requestId":"r1","method":"storage.user.get","params":{}"#))
    page.receive(
      message("request", #","requestId":"r2","method":"navigation.openSession","params":{}"#))
    page.receive(
      message("request", #","requestId":"r2","method":"navigation.openSession","params":{}"#))
    page.receive(
      message("request", #","requestId":"r3","method":"navigation.openPage","params":{}"#))
    await settle()
    let answers = port.answers()
    let errors = answers.map { answer in
      (answer["requestId"] as? String, (answer["error"] as? [String: Any])?["code"] as? String)
    }
    #expect(errors.contains { $0.0 == "r1" && $0.1 == "MethodNotFound" })
    #expect(errors.contains { $0.0 == "r2" && $0.1 == "DuplicateRequest" })
    #expect(errors.contains { $0.0 == "r3" && $0.1 == "PermissionDenied" })
    #expect(services.calls == ["navigation.openSession", "navigation.openPage"])
    services.held?.resume()
    await settle()
    let done = port.answers().last
    #expect(done?["requestId"] as? String == "r2")
    #expect((done?["result"] as? [String: Bool])?["ok"] == true)
  }

  @Test("A request past its time is answered with RequestTimeout and its late result dropped")
  func requestTimeout() async throws {
    let port = Port()
    let services = Services()
    let page = controller(
      Self.extensionItem(), reads: { _ in .loaded(text: "run()") }, services: services, port: port,
      timeout: .milliseconds(50))
    page.start()
    await settle()
    page.channel.loaded()
    page.receive(message("ready"))
    port.sent = []
    page.receive(
      message("request", #","requestId":"slow","method":"navigation.openSession","params":{}"#))
    try await Task.sleep(for: .milliseconds(200))
    let codes = port.answers().compactMap { ($0["error"] as? [String: Any])?["code"] as? String }
    #expect(codes == ["RequestTimeout"])
    services.held?.resume()
    await settle()
    #expect(port.answers().count == 1, "the late result is not sent")
  }

  @Test("A page that never says it is ready fails after the activation time")
  func activationTimeout() async throws {
    let page = controller(
      Self.extensionItem(), reads: { _ in .loaded(text: "run()") }, port: Port(),
      timeout: .milliseconds(50))
    page.start()
    try await Task.sleep(for: .milliseconds(200))
    #expect(page.state.phase == .failed("Extension activation timed out"))
    page.retry()
    await settle()
    #expect(page.state.phase == .activating)
  }

  @Test("An incompatible SDK or a page error ends the mount with its reason")
  func pageFailures() async {
    let port = Port()
    let page = controller(Self.extensionItem(), reads: { _ in .loaded(text: "run()") }, port: port)
    page.start()
    await settle()
    page.channel.loaded()
    page.receive(message("incompatible", #","sdkApiVersion":2"#))
    #expect(page.state.phase == .failed("Extension SDK API 2 is incompatible with host API 1"))
    #expect(port.sent.last?.contains(#""type":"dispose""#) == true)
  }

  @Test("Storage keeps each extension's values within the web's limits")
  func storage() throws {
    let defaults = try #require(UserDefaults(suiteName: "extension-storage-\(UUID().uuidString)"))
    let storage = ExtensionUserStorage(
      server: "https://example.com", userID: "user-1", extensionID: "example.a",
      defaults: defaults)
    let other = ExtensionUserStorage(
      server: "https://example.com", userID: "user-2", extensionID: "example.a",
      defaults: defaults)
    try storage.set(ExtensionStorageWrite(key: "k", json: "[1]", size: 3))
    #expect(storage.get("k") == "[1]")
    #expect(other.get("k") == nil, "another user's storage is apart")
    storage.delete("k")
    #expect(storage.get("k") == nil)
    let big = String(repeating: "x", count: 30 * 1024)
    for index in 0..<8 {
      try storage.set(ExtensionStorageWrite(key: "k\(index)", json: big, size: UInt64(big.count)))
    }
    #expect(throws: ExtensionHostFault.self) {
      try storage.set(ExtensionStorageWrite(key: "k9", json: big, size: UInt64(big.count)))
    }
  }
}
