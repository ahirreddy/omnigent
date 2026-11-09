import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI

/// A server with one online host where Codex needs installing and Claude needs a sign-in.
private func harnessServer(
  codex: String = #""binary-missing""#, claude: String = #""needs-auth""#, extras: String = ""
) -> AppServer {
  let server = AppServer()
  server.route(
    "/v1/hosts",
    .json(
      #"{"hosts":[{"host_id":"h1","name":"Mac","status":"online","configured_harnesses":{"codex-native":\#(codex),"claude-native":\#(claude)}\#(extras)},{"host_id":"h2","name":"Box","status":"online","configured_harnesses":{"codex-native":true}}]}"#
    ))
  server.route(
    "/v1/harnesses",
    .json(
      #"{"data":[{"id":"codex-native","label":"Codex","setup_steps":[{"kind":"install","title":"Install Codex","detail":"We'll install it.","action":"install","status_key":"installed"},{"kind":"auth","title":"Set up authentication","detail":"Sign in.","action":"auth","command":"codex login","status_key":"authed"}]},{"id":"claude-native","label":"Claude Code","setup_steps":[{"kind":"auth","title":"Set up authentication","detail":"Sign in.","action":"auth","command":"claude login","status_key":"authed"}]}]}"#
    ))
  return server
}

/// Settings > Harnesses: choosing a host, setting up and opening a harness.
@MainActor
@Suite("Harnesses settings", .serialized, .timeLimit(.minutes(1)))
struct HarnessesScreenTests {
  private func opened(
    _ server: AppServer = harnessServer()
  ) async throws -> OffscreenWindow<HarnessesSettingsView> {
    let connection = try await signedInStore(server)
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"features":{"harness_install":true},"installable_harnesses":["codex-native"]}"#
      ))
    let screen = OffscreenWindow(
      HarnessesSettingsView(connection: connection), width: 700, height: 600)
    try await settle(screen, untilShowing: "Codex")
    return screen
  }

  // Controls top to bottom: host, filter, Refresh, then Set Up and Details on each row.
  private static let refresh = 2
  private static let claudeSetUp = 3
  private static let claudeDetails = 4
  private static let codexSetUp = 5
  private static let codexDetails = 6

  private final class Backs {
    var count = 0
  }

  @Test("Refresh reads the catalog again, and another host shows its own harnesses")
  func refreshAndHost() async throws {
    let server = harnessServer()
    let screen = try await opened(server)
    defer { screen.close() }
    #expect(try screen.shows("Not installed"))
    let reads = server.requests("GET", "/v1/harnesses").count
    try screen.clickControl(at: Self.refresh)
    try await settle(screen, until: "another read") {
      server.requests("GET", "/v1/harnesses").count > reads
    }
    let menu = try screen.openMenu(screen.controlFrames[0].center)
    try screen.choose("Box", in: menu)
    try await pause(screen)
    #expect(try !screen.shows("Not installed"), "Codex is ready on Box")
  }

  @Test("Set Up installs what's missing, then reports the fresh state; Close dismisses")
  func install() async throws {
    let server = harnessServer()
    server.route(
      "/v1/hosts/h1/harnesses/codex-native/install", method: "POST",
      .json(#"{"configured_harnesses":{"codex-native":"needs-auth"}}"#))
    let screen = try await opened(server)
    defer { screen.close() }
    try screen.clickControl(at: Self.codexSetUp)
    try await settle(screen, untilShowing: "Set Up Codex on Mac")
    try screen.clickControl(at: 1)
    try await settle(screen, until: "the install") {
      !server.requests("POST", "/v1/hosts/h1/harnesses/codex-native/install").isEmpty
    }
    try await settle(
      screen, untilShowing: "Codex is installed on Mac. One more step to finish setup.")
    try screen.clickControl(at: 2)
    try await pause(screen, .milliseconds(200))
    #expect(try !screen.shows("Set Up Codex on Mac"))
  }

  @Test("Set Up Sign-In looks for credentials on the host and saves the one typed")
  func credentials() async throws {
    let server = harnessServer()
    server.route(
      "/v1/hosts/h1/credentials/detected",
      .json(
        #"{"credentials":[{"family":"anthropic","source":"$ANTHROPIC_API_KEY","env_var":"ANTHROPIC_API_KEY"}]}"#
      ))
    server.route(
      "/v1/hosts/h1/harnesses/claude-native/credential", method: "POST",
      .json(#"{"configured_harnesses":{"claude-native":true}}"#))
    let screen = try await opened(server)
    defer { screen.close() }
    try screen.clickControl(at: Self.claudeSetUp)
    try await settle(screen, untilShowing: "Set Up Claude Code on Mac")
    try screen.clickControl(at: 1)
    try await settle(screen, until: "the credential check") {
      !server.requests("GET", "/v1/hosts/h1/credentials/detected").isEmpty
    }
    try await settle(screen, untilShowing: "Found $ANTHROPIC_API_KEY on Mac.")
    try screen.clickControl(at: 2)
    try await settle(screen, until: "the credential") {
      !server.requests("POST", "/v1/hosts/h1/harnesses/claude-native/credential").isEmpty
    }
    let body = try #require(
      try server.posted("/v1/hosts/h1/harnesses/claude-native/credential").first)
    #expect(body["env_var"] as? String == "ANTHROPIC_API_KEY" || body["source"] != nil)
    try await settle(screen, untilShowing: "Claude Code is ready on Mac.")
  }

  @Test("Details names a harness and reads its startup; Back returns to the list")
  func details() async throws {
    let server = harnessServer()
    server.route(
      "/v1/hosts/h1/harnesses/claude-native/startup",
      .json(#"{"command":"claude --flag","env":{}}"#))
    let screen = try await opened(server)
    defer { screen.close() }
    try screen.clickControl(at: Self.claudeDetails)
    try await settle(screen, untilShowing: "Not signed in")
    #expect(!server.requests("GET", "/v1/hosts/h1/harnesses/claude-native/startup").isEmpty)
    try screen.clickControl(at: 0)
    try await settle(screen, untilShowing: "Search harnesses")
  }

  @Test("A harness that isn't installed offers the install in the setup sheet")
  func detailsInstall() async throws {
    let screen = try await opened()
    defer { screen.close() }
    try screen.clickControl(at: Self.codexDetails)
    try await settle(screen, untilShowing: "Not installed")
    try screen.clickControl(at: 1)
    try await settle(screen, untilShowing: "Set Up Codex on Mac")
  }

  @Test("Reconfigure shows the command to run; Check Again says if it's still not ready, then done")
  func reconfigureWithACommand() async throws {
    let server = harnessServer()
    server.route(
      "/v1/hosts/h1/harnesses/refresh", method: "POST",
      .json(#"{"host_id":"h1","configured_harnesses":{"claude-native":"needs-auth"}}"#))
    let screen = try await opened(server)
    defer { screen.close() }
    try screen.clickControl(at: Self.claudeDetails)
    try await settle(screen, untilShowing: "Not signed in")
    try screen.clickControl(at: 1)
    try await settle(screen, untilShowing: "Sign In to Claude Code on Mac")
    let controls = screen.controlFrames.count
    // Check Again is the last control but Close, and the sheet says what happened.
    try screen.clickControl(at: controls - 1)
    try await settle(screen, until: "the check") {
      !server.requests("POST", "/v1/hosts/h1/harnesses/refresh").isEmpty
    }
    try await settle(screen, untilShowing: "Still not signed in on Mac.")
    server.route(
      "/v1/hosts/h1/harnesses/refresh", method: "POST",
      .json(#"{"host_id":"h1","configured_harnesses":{"claude-native":true}}"#))
    try screen.clickControl(at: screen.controlFrames.count - 1)
    try await settle(screen, untilShowing: "Claude Code is ready on Mac.")
    try screen.clickControl(at: screen.controlFrames.count - 1)
    try await pause(screen, .milliseconds(200))
    #expect(
      try screen.shows("Claude Code is ready on Mac."), "the notice stays on the details page")
    #expect(try !screen.shows("Sign In to Claude Code on Mac"))
  }

  @Test("An update that leaves a sign-in hands over to setup")
  func updateThenContinueSetup() async throws {
    let server = harnessServer(codex: #""version-too-low""#)
    server.route(
      "/v1/hosts/h1/harnesses/codex-native/install", method: "POST",
      .json(#"{"configured_harnesses":{"codex-native":"needs-auth"},"version":"2"}"#))
    let screen = try await opened(server)
    defer { screen.close() }
    try screen.clickControl(at: Self.codexDetails)
    try await settle(screen, untilShowing: "Codex is out of date on Mac.", contains: true)
    try screen.clickControl(at: 1)
    try await settle(screen, until: "the update") {
      !server.requests("POST", "/v1/hosts/h1/harnesses/codex-native/install").isEmpty
    }
    try await pause(screen, .milliseconds(150))
    try screen.clickControl(at: screen.controlFrames.count - 1)
    try await settle(screen, untilShowing: "Set Up Sign-In")
  }

  @Test("A failed update offers Retry, which tries again")
  func updateFailsThenRetry() async throws {
    let server = harnessServer(codex: #""version-too-low""#)
    server.route(
      "/v1/hosts/h1/harnesses/codex-native/install", method: "POST",
      .json(#"{"detail":"no disk"}"#, status: 500))
    let screen = try await opened(server)
    defer { screen.close() }
    try screen.clickControl(at: Self.codexDetails)
    try await settle(screen, untilShowing: "Codex is out of date on Mac.", contains: true)
    try screen.clickControl(at: 1)
    try await settle(screen, untilShowing: "Couldn\u{2019}t Update Codex")
    let attempts = server.requests("POST", "/v1/hosts/h1/harnesses/codex-native/install").count
    try screen.clickControl(at: screen.controlFrames.count - 1)
    try await settle(screen, until: "another attempt") {
      server.requests("POST", "/v1/hosts/h1/harnesses/codex-native/install").count > attempts
    }
  }

  @Test("Switching a signed-in account signs out, then shows the device code; Close cancels it")
  func switchAccount() async throws {
    let server = harnessServer(
      codex: "true",
      extras:
        #","harness_login_supported":true,"harness_accounts":{"codex":{"kind":"chatgpt","email":"a@b.co"}}"#
    )
    server.route(
      "/v1/hosts/h1/harnesses/codex/logout", method: "POST",
      .json(#"{"configured_harnesses":{"codex-native":"needs-auth"},"harness_accounts":null}"#))
    server.route(
      "/v1/hosts/h1/harnesses/codex/login", method: "POST",
      .json(
        #"{"login_id":"l1","verification_url":"https://auth.openai.com/device","user_code":"AB-12","expires_at":4000000000}"#
      ))
    server.route(
      "/v1/hosts/h1/harnesses/codex/login/l1", method: "GET",
      .json(#"{"status":"pending","error":null,"expired":false}"#))
    server.route("/v1/hosts/h1/harnesses/codex/login/l1", method: "DELETE", .json("{}"))
    let screen = try await opened(server)
    defer { screen.close() }
    try screen.clickControl(at: 5)
    try await settle(screen, untilShowing: "Machine")
    try screen.clickControl(at: 1)
    try await settle(screen, untilShowing: "Switch Codex Account?")
    #expect(try screen.shownText().contains { $0.contains("a@b.co") })
    try screen.clickControl(at: screen.controlFrames.count - 1)
    try await settle(screen, untilShowing: "AB-12")
    #expect(!server.requests("POST", "/v1/hosts/h1/harnesses/codex/logout").isEmpty)
    try screen.clickControl(at: screen.controlFrames.count - 1)
    try await settle(screen, until: "the sign-in to end") {
      !server.requests("DELETE", "/v1/hosts/h1/harnesses/codex/login/l1").isEmpty
    }
  }

  @Test("A harness on a host that left says so and offers the way back")
  func aHostThatLeft() async throws {
    let server = harnessServer()
    let connection = try await signedInStore(server)
    let store = try #require(connection.harnessSetup())
    let fix = try #require(connection.harnessFix(setup: store))
    await store.load()
    var target: HarnessSetupTarget?
    let backs = Backs()
    let screen = OffscreenWindow(
      Form {
        HarnessDetailContainer(
          setup: store, fix: fix, harness: "codex-native", name: "Codex", hostID: "gone",
          back: { backs.count += 1 },
          setupTarget: Binding(get: { target }, set: { target = $0 }))
      }, width: 500, height: 300)
    defer { screen.close() }
    try await settle(screen, untilShowing: "This host is no longer connected.")
    try screen.clickControl(at: 0)
    #expect(backs.count == 1)
  }

  @Test("A catalog that can't be read says why")
  func failure() async throws {
    let server = harnessServer()
    let connection = try await signedInStore(server)
    server.route("/v1/hosts", .json(#"{"detail":"down"}"#, status: 500))
    let screen = OffscreenWindow(
      HarnessesSettingsView(connection: connection), width: 700, height: 600)
    defer { screen.close() }
    try await settle(
      screen, untilShowing: "The server returned HTTP 500. Check that it is running and try again.")
  }
}

extension CGRect {
  fileprivate var center: CGPoint { CGPoint(x: midX, y: midY) }
}
