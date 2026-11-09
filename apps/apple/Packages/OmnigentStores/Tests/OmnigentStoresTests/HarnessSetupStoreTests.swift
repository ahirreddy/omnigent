import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// Installing a harness and writing its credential, on the sheet and in Settings.
@MainActor
@Suite("Harness setup", .timeLimit(.minutes(1)))
struct HarnessSetupStoreTests {
  private let hosts = #"""
    {"hosts":[{"host_id":"h1","name":"Mac","status":"online","configured_harnesses":{"codex-native":"binary-missing"}}]}
    """#
  private let key = HarnessCredentialInput.key(secret: "sk-1")

  private func serverWithCatalog() -> RouteServer {
    let server = RouteServer()
    server.route("/v1/hosts", .json(hosts))
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"accounts_enabled":false,"features":{"harness_install":true},"installable_harnesses":["codex-native"]}"#
      ))
    server.route(
      "/v1/harnesses",
      .json(#"{"data":[{"id":"codex-native","label":"Codex","setup_steps":[]}]}"#))
    return server
  }

  private func loaded(_ server: RouteServer) async throws -> HarnessSetupStore {
    let setup = try #require(try await connectedStore(server).harnessSetup())
    await setup.load()
    return setup
  }

  @Test("Before the catalog loads there is nothing to show; a failed read says so")
  func beforeLoad() async throws {
    let server = serverWithCatalog()
    server.fail("/v1/hosts")
    let setup = try #require(try await connectedStore(server).harnessSetup())
    #expect(setup.plan(harness: "codex-native", hostID: "h1") == nil)
    #expect(setup.inventory(hostID: "h1").isEmpty)
    #expect(setup.detail(harness: "codex-native", name: "Codex", hostID: "h1") == nil)
    await setup.load()
    guard case .failed = setup.catalog else {
      Issue.record("catalog: \(setup.catalog)")
      return
    }
  }

  @Test("The catalog gives the sheet its plan and Settings its list")
  func loads() async throws {
    let setup = try await loaded(serverWithCatalog())
    #expect(setup.plan(harness: "codex-native", hostID: "h1") != nil)
    #expect(!setup.inventory(hostID: "h1").isEmpty)
    #expect(setup.detail(harness: "codex-native", name: "Codex", hostID: "h1") != nil)
    #expect(setup.detail(harness: "codex-native", name: "Codex", hostID: "nowhere") == nil)
    await setup.load()
    #expect(setup.catalog.value != nil, "a reload keeps what was shown")
  }

  @Test("Installing tells the user what's left, or why it failed")
  func installs() async throws {
    let server = serverWithCatalog()
    let setup = try await loaded(server)
    await setup.install(harness: "codex-native", label: "Codex", hostID: "h1")
    #expect(setup.error != nil)
    #expect(!setup.isInstalling(harness: "codex-native", hostID: "h1"))

    let install = "/v1/hosts/h1/harnesses/codex-native/install"
    server.route(install, .json(#"{"configured_harnesses":{"codex-native":"needs-auth"}}"#))
    await setup.install(harness: "codex-native", label: "Codex", hostID: "h1")
    #expect(setup.error == nil)
    #expect(setup.notice == "Codex is installed on Mac. One more step to finish setup.")

    server.route(
      "/v1/hosts/elsewhere/harnesses/codex-native/install",
      .json(#"{"configured_harnesses":{"codex-native":true}}"#))
    await setup.install(harness: "codex-native", label: "Codex", hostID: "elsewhere")
    #expect(setup.notice == "Codex is ready on the host.")
    setup.dismissMessages()
    #expect(setup.notice == nil)
  }

  @Test("A second install of the same harness doesn't start while one runs")
  func installOnce() async throws {
    let server = serverWithCatalog()
    let install = "/v1/hosts/h1/harnesses/codex-native/install"
    server.route(install, .json(#"{"configured_harnesses":{"codex-native":true}}"#))
    let gate = server.hold(install)
    let setup = try await loaded(server)
    let installing = Task {
      await setup.install(harness: "codex-native", label: "Codex", hostID: "h1")
    }
    try await eventually("the install") { gate.arrivals == 1 }
    #expect(setup.isInstalling(harness: "codex-native", hostID: "h1"))
    await setup.install(harness: "codex-native", label: "Codex", hostID: "h1")
    gate.release()
    await installing.value
    #expect(server.requests(to: install).count == 1)
    #expect(setup.notice == "Codex is ready on Mac.")
  }

  @Test("A saved credential reports whether the harness is ready, and rereads what's detected")
  func credentials() async throws {
    let server = serverWithCatalog()
    let credential = "/v1/hosts/h1/harnesses/codex-native/credential"
    let setup = try await loaded(server)
    #expect(
      await !setup.storeCredential(key, harness: "codex-native", label: "Codex", hostID: "h1"))
    #expect(setup.error != nil)
    #expect(!setup.isSavingCredential)

    server.route(credential, .json(#"{"configured_harnesses":{"codex-native":"needs-auth"}}"#))
    #expect(
      await !setup.storeCredential(key, harness: "codex-native", label: "Codex", hostID: "h1"))
    #expect(setup.notice?.hasPrefix("Saved, but Codex still needs setup") == true)

    server.route(credential, .json(#"{"configured_harnesses":{"codex-native":true}}"#))
    #expect(await setup.storeCredential(key, harness: "codex-native", label: "Codex", hostID: "h1"))
    #expect(setup.notice == "Codex is ready on Mac.")
  }

  @Test("A second save waits for the first")
  func saveOnce() async throws {
    let server = serverWithCatalog()
    let credential = "/v1/hosts/h1/harnesses/codex-native/credential"
    server.route(credential, .json(#"{"configured_harnesses":{"codex-native":true}}"#))
    let gate = server.hold(credential)
    let setup = try await loaded(server)
    let key = self.key
    let saving = Task {
      await setup.storeCredential(key, harness: "codex-native", label: "Codex", hostID: "h1")
    }
    try await eventually("the save") { gate.arrivals == 1 }
    #expect(setup.isSavingCredential)
    #expect(
      await !setup.storeCredential(key, harness: "codex-native", label: "Codex", hostID: "h1"))
    gate.release()
    #expect(await saving.value)
    #expect(server.requests(to: credential).count == 1)
  }

  @Test("Detected credentials read once per host until one is saved")
  func detected() async throws {
    let server = serverWithCatalog()
    let path = "/v1/hosts/h1/credentials/detected"
    let setup = try await loaded(server)
    await setup.loadDetected(hostID: "h1")
    guard case .failed = setup.detected["h1"] else {
      Issue.record("detected: \(String(describing: setup.detected["h1"]))")
      return
    }

    let other = try await loaded(server)
    server.route(
      path,
      .json(#"{"credentials":[{"family":"openai","source":"env","env_var":"OPENAI_API_KEY"}]}"#))
    await other.loadDetected(hostID: "h1")
    #expect(other.detected["h1"]?.value?.first?.envVar == "OPENAI_API_KEY")
    let reads = server.requests(to: path).count
    await other.loadDetected(hostID: "h1")
    #expect(server.requests(to: path).count == reads)

    server.route(
      "/v1/hosts/h1/harnesses/codex-native/credential",
      .json(#"{"configured_harnesses":{"codex-native":true}}"#))
    await other.storeCredential(key, harness: "codex-native", label: "Codex", hostID: "h1")
    #expect(other.detected["h1"] == nil, "a saved credential changes what's detected")
  }

  @Test("A host's reported readiness replaces its row only once the catalog loaded")
  func snapshots() async throws {
    let setup = try #require(try await connectedStore(serverWithCatalog()).harnessSetup())
    let snapshot = HarnessHostSnapshot(harnesses: [], accounts: [], gatewayInference: nil)
    setup.apply(snapshot, hostID: "h1")
    #expect(setup.catalog.value == nil)
    await setup.load()
    let before = setup.catalog.value
    setup.apply(snapshot, hostID: "nowhere")
    #expect(setup.catalog.value == before)
  }
}
