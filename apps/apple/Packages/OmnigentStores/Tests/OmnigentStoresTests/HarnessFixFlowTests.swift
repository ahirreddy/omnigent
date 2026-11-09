import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

private let loginPath = "/v1/hosts/h1/harnesses/codex/login"
private let started = HttpResponse.json(
  #"{"login_id":"l1","verification_url":"https://auth.openai.com/codex/device","user_code":"AB-12","expires_at":4102444800}"#
)
private let finishedStatus =
  #"{"status":"succeeded","error":null,"expired":false,"configured_harnesses":{"codex-native":true}}"#

@MainActor
private func codex(_ setup: HarnessSetupStore) throws -> HarnessDetail {
  try #require(setup.detail(harness: "codex-native", name: "Codex", hostID: "h1"))
}

@MainActor
private func hasFailed(_ fix: HarnessFixStore) -> Bool {
  if case .failed = fix.phase { return true }
  return false
}

@MainActor
private func finished(_ fix: HarnessFixStore) async throws {
  try await eventually("the flow to finish") {
    switch fix.phase {
    case .done, .failed: true
    default: false
    }
  }
}

/// The harness fix flow's other branches: every step can fail, and a closed sheet stops it.
@MainActor
@Suite("Fixing a harness", .timeLimit(.minutes(1)))
struct HarnessFixFlowTests {
  @Test("Reconfigure runs the device sign-in when the host supports it")
  func reconfigureDevice() async throws {
    let server = RouteServer()
    let (setup, fix) = try await harnessFixStores(server)
    server.route(loginPath, started)
    server.route("\(loginPath)/l1", .json(finishedStatus))
    await fix.begin(.reconfigure, detail: try codex(setup), hostID: "h1")
    try await finished(fix)
    #expect(fix.phase == .done("Codex is ready on Mac. Signed in as old@x.io."))
  }

  @Test("Reconfigure falls back to a command to run, then to plain setup advice")
  func reconfigureFallbacks() async throws {
    let (setup, fix) = try await harnessFixStores(RouteServer())
    var detail = try codex(setup)
    detail.supportsDeviceLogin = false
    detail.personalLoginCommand = "codex login"
    await fix.begin(.reconfigure, detail: detail, hostID: "h1")
    #expect(fix.phase == .runCommand("codex login", stillNotReady: false))

    detail.personalLoginCommand = nil
    await fix.begin(.reconfigure, detail: detail, hostID: "h1")
    #expect(fix.phase == .needsSetup("Set up Codex on Mac."))
  }

  @Test("A sign-out the host refuses is shown, and the catalog stays as it was")
  func signOutRefused() async throws {
    let server = RouteServer()
    let (setup, fix) = try await harnessFixStores(server)
    server.fail("/v1/hosts/h1/harnesses/codex/logout", status: 400, detail: "busy")
    await fix.confirmSwitch(detail: try codex(setup), hostID: "h1", email: nil)
    #expect(fix.phase == .failed("busy"))
    #expect(try codex(setup).ready)
  }

  @Test("Signed out with no way to sign in from here asks for setup")
  func switchWithoutCommand() async throws {
    let server = RouteServer()
    let (setup, fix) = try await harnessFixStores(server)
    server.route(
      "/v1/hosts/h1/harnesses/goose/logout",
      .json(#"{"configured_harnesses":{"goose-native":"needs-auth"}}"#))
    var detail = try codex(setup)
    detail.harness = "goose-native"
    detail.name = "Goose"
    detail.supportsDeviceLogin = false
    await fix.confirmSwitch(detail: detail, hostID: "h1", email: nil)
    #expect(fix.phase == .needsSetup("Sign in to Goose on Mac."))
  }

  @Test("A sign-in the host won't start says why")
  func loginRefused() async throws {
    let server = RouteServer()
    let (setup, fix) = try await harnessFixStores(server)
    server.fail(loginPath, status: 400, detail: "no network")
    await fix.startDeviceLogin(detail: try codex(setup), hostID: "h1")
    #expect(fix.phase == .failed("no network"))
  }

  @Test("Another sign-in already running is waited for, through pending, to its end")
  func waitsForOtherSignIn() async throws {
    let server = RouteServer()
    let (setup, fix) = try await harnessFixStores(server)
    server.route(
      loginPath, .json(#"{"error":{"code":"login_busy","login_id":"l9"}}"#, status: 409))
    server.route(
      "\(loginPath)/l9", .json(#"{"status":"pending","error":null,"expired":false}"#))
    await fix.startDeviceLogin(detail: try codex(setup), hostID: "h1")
    #expect(fix.phase == .waitingForOtherSignIn)
    try await eventually("a poll") { server.requests(to: "\(loginPath)/l9").count >= 2 }
    #expect(fix.phase == .waitingForOtherSignIn)

    server.route("\(loginPath)/l9", .json(finishedStatus))
    try await finished(fix)
    #expect(fix.phase == .done("Codex is ready on Mac. Signed in as old@x.io."))
  }

  @Test(
    "A sign-in that ends badly says so, with the host's reason when it gave one",
    arguments: [
      (#"{"status":"failed","error":"denied","expired":false}"#, "denied"),
      (#"{"status":"failed","error":null,"expired":false}"#, "The sign-in did not complete."),
      (#"{"status":"cancelled","error":null,"expired":false}"#, "The sign-in did not complete."),
    ])
  func loginEndsBadly(status: String, shown: String) async throws {
    let server = RouteServer()
    let (setup, fix) = try await harnessFixStores(server)
    server.route(loginPath, started)
    server.route("\(loginPath)/l1", .json(status))
    await fix.startDeviceLogin(detail: try codex(setup), hostID: "h1")
    try await finished(fix)
    #expect(fix.phase == .failed(shown))
  }

  @Test("A status read that fails ends the wait with the reason")
  func pollFails() async throws {
    let server = RouteServer()
    let (setup, fix) = try await harnessFixStores(server)
    server.route(loginPath, started)
    server.fail("\(loginPath)/l1", status: 500)
    await fix.startDeviceLogin(detail: try codex(setup), hostID: "h1")
    try await finished(fix)
    #expect(hasFailed(fix))
  }

  @Test("A finished sign-in with no readiness in it asks the host; that read can fail too")
  func finishWithoutSnapshot() async throws {
    let server = RouteServer()
    let (setup, fix) = try await harnessFixStores(server)
    server.route(loginPath, started)
    server.route(
      "\(loginPath)/l1", .json(#"{"status":"succeeded","error":null,"expired":false}"#))
    server.route(
      "/v1/hosts/h1/harnesses/refresh", .json(#"{"configured_harnesses":{"codex-native":true}}"#))
    await fix.startDeviceLogin(detail: try codex(setup), hostID: "h1")
    try await finished(fix)
    #expect(server.requests(to: "/v1/hosts/h1/harnesses/refresh").count == 1)
    guard case .done = fix.phase else {
      Issue.record("phase: \(fix.phase)")
      return
    }

    server.fail("/v1/hosts/h1/harnesses/refresh", status: 400, detail: "asleep")
    await fix.startDeviceLogin(detail: try codex(setup), hostID: "h1")
    try await finished(fix)
    #expect(hasFailed(fix))
  }

  @Test("Closing the sheet cancels the sign-in on the host, and a refusal changes nothing")
  func cancelStopsTheSignIn() async throws {
    let server = RouteServer()
    let (setup, fix) = try await harnessFixStores(server)
    server.route(loginPath, started)
    server.route(
      "\(loginPath)/l1", .json(#"{"status":"pending","error":null,"expired":false}"#))
    server.route("\(loginPath)/l1", method: "DELETE", .json("{}"))
    await fix.startDeviceLogin(detail: try codex(setup), hostID: "h1")
    try await eventually("a poll") {
      !server.requests(to: "\(loginPath)/l1", method: "GET").isEmpty
    }
    fix.cancel()
    #expect(fix.phase == .idle)
    try await eventually("the cancel") {
      server.requests(to: "\(loginPath)/l1", method: "DELETE").count == 1
    }

    server.fail("\(loginPath)/l1", method: "DELETE")
    await fix.startDeviceLogin(detail: try codex(setup), hostID: "h1")
    fix.cancel()
    try await eventually("the refused cancel") {
      server.requests(to: "\(loginPath)/l1", method: "DELETE").count == 2
    }
    #expect(fix.phase == .idle, "the flow already stopped")
    fix.cancel()
    #expect(server.requests(to: "\(loginPath)/l1", method: "DELETE").count == 2)
  }

  @Test("Closing the sheet between status reads ends the wait without another read")
  func cancelledBetweenPolls() async throws {
    let server = RouteServer()
    let (setup, _) = try await harnessFixStores(server)
    server.route(loginPath, started)
    server.route(
      "\(loginPath)/l1", method: "GET", .json(#"{"status":"pending","error":null,"expired":false}"#)
    )
    server.route("\(loginPath)/l1", method: "DELETE", .json("{}"))
    let connection = try await connectedStore(server)
    let core = try #require(connection.core)
    let fix = HarnessFixStore(core: core, setup: setup, pollInterval: .seconds(60))
    await fix.startDeviceLogin(detail: try codex(setup), hostID: "h1")
    try await Task.sleep(for: .milliseconds(20))
    fix.cancel()
    try await Task.sleep(for: .milliseconds(20))
    #expect(server.requests(to: "\(loginPath)/l1", method: "GET").isEmpty)
    #expect(fix.phase == .idle)
  }

  @Test("A sign-in that starts after the sheet closed is cancelled on the host")
  func cancelledWhileStarting() async throws {
    let server = RouteServer()
    let (setup, fix) = try await harnessFixStores(server)
    server.route(loginPath, method: "POST", started)
    server.route("\(loginPath)/l1", method: "DELETE", .json("{}"))
    let gate = server.hold(loginPath, method: "POST")
    let detail = try codex(setup)
    async let start: Void = fix.startDeviceLogin(detail: detail, hostID: "h1")
    try await eventually("the start") { gate.arrivals > 0 }
    fix.cancel()
    gate.release()
    await start
    #expect(fix.phase == .idle)
    #expect(server.requests(to: "\(loginPath)/l1", method: "DELETE").count == 1)
  }

  @Test("A step that answers after the sheet closed changes nothing")
  func staleSteps() async throws {
    let server = RouteServer()
    let (setup, fix) = try await harnessFixStores(server)
    let detail = try codex(setup)

    let install = server.hold("/v1/hosts/h1/harnesses/codex-native/install")
    server.route(
      "/v1/hosts/h1/harnesses/codex-native/install",
      .json(#"{"configured_harnesses":{"codex-native":true}}"#))
    async let installing: Void = fix.begin(.install, detail: detail, hostID: "h1")
    try await eventually("the install") { install.arrivals > 0 }
    fix.cancel()
    install.release()
    await installing
    #expect(fix.phase == .idle)

    let signOut = server.hold("/v1/hosts/h1/harnesses/codex/logout")
    server.route(
      "/v1/hosts/h1/harnesses/codex/logout",
      .json(#"{"configured_harnesses":{"codex-native":"needs-auth"}}"#))
    async let signingOut: Void = fix.confirmSwitch(detail: detail, hostID: "h1", email: nil)
    try await eventually("the sign-out") { signOut.arrivals > 0 }
    fix.cancel()
    signOut.release()
    await signingOut
    #expect(fix.phase == .idle)
    #expect(try codex(setup).ready, "the closed sheet's answer isn't applied")
  }
}

/// The steps of the fix flow that don't sign in.
@MainActor
@Suite("Harness checks", .timeLimit(.minutes(1)))
struct HarnessCheckTests {
  @Test("Installing reports the install, and still asks for setup when the host needs it")
  func installs() async throws {
    let server = RouteServer()
    let (setup, fix) = try await harnessFixStores(server)
    let detail = try codex(setup)
    let path = "/v1/hosts/h1/harnesses/codex-native/install"
    server.route(path, .json(#"{"configured_harnesses":{"codex-native":true}}"#))
    await fix.begin(.install, detail: detail, hostID: "h1")
    #expect(fix.phase == .done("Codex is ready on Mac."))

    server.route(path, .json(#"{"configured_harnesses":{"codex-native":"needs-auth"}}"#))
    await fix.begin(.install, detail: detail, hostID: "h1")
    #expect(fix.phase == .needsSetup("Codex was installed but still needs to be set up on Mac."))
  }

  @Test("Check Again runs once at a time, and a failed one says why")
  func checksAgain() async throws {
    let server = RouteServer()
    let (setup, fix) = try await harnessFixStores(server)
    let detail = try codex(setup)
    let path = "/v1/hosts/h1/harnesses/refresh"
    server.fail(path, method: "POST", status: 400, detail: "asleep")
    await fix.checkAgain(detail: detail, hostID: "h1")
    #expect(hasFailed(fix))
    #expect(!fix.isChecking)

    let gate = server.hold(path, method: "POST")
    async let first: Void = fix.checkAgain(detail: detail, hostID: "h1")
    try await eventually("the check") { gate.arrivals > 0 }
    #expect(fix.isChecking)
    await fix.checkAgain(detail: detail, hostID: "h1")
    #expect(gate.arrivals == 1)
    fix.cancel()
    server.route(path, method: "POST", .json(#"{"configured_harnesses":{"codex-native":true}}"#))
    gate.release()
    await first
    #expect(fix.phase == .idle, "the closed sheet's answer isn't shown")
  }

  @Test("Startup commands read once per host and harness, and keep a failure")
  func startupReads() async throws {
    let server = RouteServer()
    let (_, fix) = try await harnessFixStores(server)
    let path = "/v1/hosts/h1/harnesses/codex-native/startup"
    server.fail(path, status: 500)
    await fix.loadStartup(harness: "codex-native", hostID: "h1", hostName: "Mac")
    guard case .failed = fix.startup["h1/codex-native"] else {
      Issue.record("startup: \(String(describing: fix.startup["h1/codex-native"]))")
      return
    }
    await fix.loadStartup(harness: "codex-native", hostID: "h1", hostName: "Mac")
    #expect(server.requests(to: path).count == 1)
  }

  @Test("The connection hands out a flow over the setup store")
  func vended() async throws {
    let connection = try await connectedStore(RouteServer())
    let setup = try #require(connection.harnessSetup())
    #expect(connection.harnessFix(setup: setup)?.phase == .idle)
  }
}
