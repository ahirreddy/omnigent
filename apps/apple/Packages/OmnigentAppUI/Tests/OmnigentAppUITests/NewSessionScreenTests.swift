import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI

/// The real page in an offscreen window: what is typed and picked is what starts.
@MainActor
@Suite("New session screen", .serialized, .timeLimit(.minutes(1)))
struct NewSessionScreenTests {
  // Where the composer's menus sit in a 900 point wide window.
  private static let hostMenu = CGPoint(x: 124, y: 423)
  private static let agentMenu = CGPoint(x: 676, y: 423)
  private static let modeMenu = CGPoint(x: 784, y: 423)

  private func startableServer() -> AppServer {
    let server = newSessionServer()
    let row = sessionRow("conv_a", host: "mac", workspace: "/work/recent", updatedAt: 5)
    server.route(
      "/v1/sessions", method: "GET", .json(#"{"object":"list","data":[\#(row)],"has_more":false}"#))
    server.route(
      "/v1/sessions/conv_new",
      .json(
        #"{"id":"conv_new","status":"idle","created_at":1,"agent_id":"ag_claude","host_id":"mac","permission_level":4}"#
      ))
    server.route(
      "/v1/sessions/conv_new/events", method: "POST", .json(#"{"queued":false}"#, status: 202))
    return server
  }

  private final class Opened {
    var sessions: [String] = []
  }

  private func page(
    _ server: AppServer, width: CGFloat = 900
  ) async throws -> (OffscreenWindow<NewSessionContainer>, Opened) {
    SystemSideEffects.reset()
    let connection = try await signedInStore(server)
    try await eventually("the session list") { connection.sessionList.isLoaded }
    let opened = Opened()
    let screen = OffscreenWindow(
      NewSessionContainer(connection: connection, form: try isolatedForm()) {
        opened.sessions.append($0)
      },
      width: width, height: 700)
    try await settle(screen, until: "the folder listing") {
      !server.requests("GET", "/v1/hosts/mac/filesystem").isEmpty
    }
    try await pause(screen, .milliseconds(150))
    return (screen, opened)
  }

  private func typeAndStart(
    _ screen: OffscreenWindow<NewSessionContainer>, _ server: AppServer
  ) async throws -> [String: Any] {
    try screen.type("hello")
    try screen.press(keyCode: 36, characters: "\r")
    try await settle(screen, until: "the create") {
      !server.requests("POST", "/v1/sessions").isEmpty
    }
    return try #require(try server.posted("/v1/sessions").first)
  }

  @Test("Typing and pressing Return creates the session in the recent folder and opens it")
  func typeAndReturnStarts() async throws {
    let server = startableServer()
    let (screen, opened) = try await page(server)
    defer { screen.close() }
    #expect(try screen.shows("mac · recent"), "the folder comes from the most recent session")
    let body = try await typeAndStart(screen, server)
    #expect(body["workspace"] as? String == "/work/recent")
    #expect(body["host_id"] as? String == "mac")
    #expect(body["agent_id"] as? String == "ag_claude")
    try await settle(screen, until: "the session opens") { !opened.sessions.isEmpty }
    #expect(opened.sessions == ["conv_new"])
    let message = try #require(try server.posted("/v1/sessions/conv_new/events").first)
    #expect(String(describing: message).contains("hello"))
    let shown = try screen.shownText()
    #expect(shown.contains { $0.contains("What should we build?") }, "\(shown)")
    #expect(!shown.contains { $0.contains("hello") }, "the composer is empty for the next session")
  }

  @Test("The agent, model and mode picked in their menus are what the request sends")
  func pickedInMenusIsSent() async throws {
    let server = startableServer()
    let (screen, _) = try await page(server)
    defer { screen.close() }
    try screen.choose("Codex", in: menu(screen, at: Self.agentMenu, offering: "Codex"))
    try await pause(screen)
    try screen.choose(
      "codex-native-fast", in: menu(screen, at: Self.agentMenu, offering: "codex-native-fast"))
    try await pause(screen)
    let body = try await typeAndStart(screen, server)
    #expect(body["agent_id"] as? String == "ag_codex")
    #expect(body["model_override"] as? String == "codex-native-fast")
  }

  @Test("An approval mode picked in the chip is shown and sent")
  func pickedModeIsSent() async throws {
    let server = startableServer()
    let (screen, _) = try await page(server)
    defer { screen.close() }
    try screen.choose("Full access", in: menu(screen, at: Self.modeMenu, offering: "Full access"))
    try await pause(screen)
    #expect(try screen.shows("Full access"))
    let body = try await typeAndStart(screen, server)
    #expect((body["terminal_launch_args"] as? [String])?.first == "--permission-mode")
    #expect((body["terminal_launch_args"] as? [String])?.count == 2)
  }

  @Test("Picking another host in the chip drops the folder until one is chosen there")
  func pickedHostDropsTheFolder() async throws {
    let server = startableServer()
    let (screen, _) = try await page(server)
    defer { screen.close() }
    try screen.choose("box", in: menu(screen, at: Self.hostMenu, offering: "box"))
    try await pause(screen, .milliseconds(120))
    let shown = try screen.shownText()
    #expect(shown.contains { $0.contains("box") }, "\(shown)")
    #expect(!shown.contains { $0.contains("recent") }, "\(shown)")
    #expect(!server.requests("GET", "/v1/hosts/box/filesystem").isEmpty)
    try screen.type("hello")
    try screen.press(keyCode: 36, characters: "\r")
    try await pause(screen)
    let body = try #require(try server.posted("/v1/sessions").first)
    #expect(body["host_id"] as? String == "box")
    #expect(body["workspace"] as? String != "/work/recent", "that path belongs to the other host")
  }

  @Test("A first message that fails says so, and Dismiss opens the session that was created")
  func aFailedFirstMessageOpensOnDismiss() async throws {
    let server = startableServer()
    server.route(
      "/v1/sessions/conv_new/events", method: "POST", .json(#"{"detail":"nope"}"#, status: 422))
    let (screen, opened) = try await page(server)
    defer { screen.close() }
    _ = try await typeAndStart(screen, server)
    try await pause(screen, .milliseconds(150))
    #expect(try screen.shows("Message not sent"))
    #expect(opened.sessions.isEmpty, "the user must see the failure first")
    #expect(try screen.shows("hello"), "the words aren't lost")

    // The notice sits above the composer, so its Dismiss is the first control in reading order.
    try screen.clickControl(at: 0)
    try await settle(screen, until: "the session opens") { !opened.sessions.isEmpty }
    #expect(opened.sessions == ["conv_new"])
  }

  @Test("A refused create shows the server's reason, opens nothing and keeps the words")
  func aRefusedCreateStays() async throws {
    let server = startableServer()
    server.route(
      "/v1/sessions", method: "POST", .json(#"{"detail":"folder is not allowed"}"#, status: 422))
    let (screen, opened) = try await page(server)
    defer { screen.close() }
    _ = try await typeAndStart(screen, server)
    try await pause(screen, .milliseconds(150))
    #expect(try screen.shows("folder is not allowed"))
    #expect(try screen.shows("hello"))
    #expect(opened.sessions.isEmpty)
    #expect(server.requests("POST", "/v1/sessions").count == 1)
  }

  @Test("A create whose answer is lost isn't repeated by pressing Return again")
  func aLostAnswerBlocksAnotherStart() async throws {
    let server = startableServer()
    server.route("/v1/sessions", method: "POST", .json(#"{"detail":"gateway"}"#, status: 502))
    let (screen, opened) = try await page(server)
    defer { screen.close() }
    _ = try await typeAndStart(screen, server)
    try await pause(screen, .milliseconds(150))
    try screen.press(keyCode: 36, characters: "\r")
    try await pause(screen)
    #expect(server.requests("POST", "/v1/sessions").count == 1, "creation is never repeated")
    #expect(opened.sessions.isEmpty)
  }

  @Test("Offline hosts: the page offers Connect instead of starting")
  func noHostOnline() async throws {
    let server = newSessionServer(offline: ["mac", "box"])
    SystemSideEffects.reset()
    let connection = try await signedInStore(server)
    let screen = OffscreenWindow(
      NewSessionContainer(connection: connection, form: try isolatedForm()) { _ in }, width: 900,
      height: 700)
    defer { screen.close() }
    try await pause(screen, .milliseconds(200))
    try screen.type("hello")
    try screen.press(keyCode: 36, characters: "\r")
    try await pause(screen)
    #expect(server.requests("POST", "/v1/sessions").isEmpty)
    let shown = try screen.shownText()
    #expect(shown.contains { $0.contains("host") || $0.contains("Connect") }, "\(shown)")
  }

  @Test("A long folder and branch stay inside a narrow window")
  func chipsFitANarrowWindow() async throws {
    let server = startableServer()
    let long = "/work/" + String(repeating: "very-long-folder-name-", count: 8)
    let row = sessionRow("conv_a", host: "mac", workspace: long, updatedAt: 5)
    server.route(
      "/v1/sessions", method: "GET", .json(#"{"object":"list","data":[\#(row)],"has_more":false}"#))
    let (screen, _) = try await page(server, width: 480)
    defer { screen.close() }
    let tooWide = screen.allViews.filter { view in
      guard view is NSControl else { return false }
      let frame = view.convert(view.bounds, to: screen.host)
      return frame.maxX > 481 || frame.minX < -1
    }
    let frames = tooWide.map { $0.convert($0.bounds, to: screen.host) }
    #expect(tooWide.isEmpty, "controls past the window's edge: \(frames)")
  }
}
