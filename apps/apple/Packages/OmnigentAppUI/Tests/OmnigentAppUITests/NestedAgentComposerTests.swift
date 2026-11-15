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

/// The Add nested agent composer in an offscreen window: what it says, what Start sends, and
/// what follows.
@MainActor
@Suite("Add nested agent composer", .serialized, .timeLimit(.minutes(1)))
struct NestedAgentComposerTests {
  private func composer(
    _ server: AppServer, sourceID: String = "conv_src", drafts: [String: String] = [:]
  ) async throws -> (OffscreenWindow<NewSessionContainer>, NestedRoutes) {
    SystemSideEffects.reset()
    let connection = try await signedInStore(server)
    try await eventually("the session list") { connection.sessionList.isLoaded }
    connection.creation()?.composerDrafts = drafts
    let routes = NestedRoutes(connection: connection)
    let screen = OffscreenWindow(
      NewSessionContainer(
        connection: connection, form: try isolatedForm(), nestedSourceID: sourceID,
        open: { routes.opened.append($0) },
        openWithNotice: {
          routes.opened.append($0)
          routes.notices.append($1)
        },
        continueInNewSession: { routes.continued += 1 }),
      width: 900, height: 700)
    try await pause(screen, .milliseconds(150))
    return (screen, routes)
  }

  private func typeAndStart(
    _ screen: OffscreenWindow<NewSessionContainer>, _ server: AppServer, text: String = "hello"
  ) async throws -> [String: Any] {
    let field = try #require(screen.allViews.first { $0 is NSTextView })
    try screen.click(field)
    try screen.type(text)
    try screen.press(keyCode: 36, characters: "\r")
    try await settle(screen, until: "the create") {
      !server.requests("POST", "/v1/sessions").isEmpty
    }
    return try #require(try server.posted("/v1/sessions").first)
  }

  @Test("It shows its heading, its source and its prompt, and no project")
  func headingSourceAndPrompt() async throws {
    let (screen, _) = try await composer(nestedServer())
    defer { screen.close() }
    try await settle(screen, untilShowing: "Add nested agent")
    #expect(try screen.shows("A new conversation alongside Coordinator"))
    #expect(try screen.shows("What should this agent work on?"))
    #expect(try screen.shows("mac · app"), "the source's folder is preselected")
    #expect(try !screen.shows("No project"))
    #expect(try !screen.shows("What should we build?"))
  }

  @Test("Start sends the source and a fresh token, never a project, and opens the session")
  func startSendsTheSource() async throws {
    let server = nestedServer()
    let (screen, routes) = try await composer(server)
    defer { screen.close() }
    try await settle(screen, untilShowing: "mac · app")
    let body = try await typeAndStart(screen, server)
    #expect(body["sibling_source_id"] as? String == "conv_src")
    #expect(body["host_id"] as? String == "mac")
    #expect(body["workspace"] as? String == "/work/app")
    #expect(body["project_id"] == nil)
    #expect(body["git"] == nil, "the source's checkout is reused")
    let labels = try #require(body["labels"] as? [String: String])
    let token = try #require(labels["omnigent.client_create_token"])
    #expect(token.count == 32 && token.allSatisfy(\.isHexDigit))
    try await settle(screen, until: "the session opens") { !routes.opened.isEmpty }
    #expect(routes.opened == ["conv_new"])
    #expect(routes.notices.isEmpty)
    #expect(String(describing: try server.posted("/v1/sessions/conv_new/events")).contains("hello"))
  }

  @Test("The server's refusal shows in clear words and opens nothing")
  func refusalShowsTheReason() async throws {
    let server = nestedServer()
    server.route(
      "/v1/sessions", method: "POST",
      .json(
        #"{"error":{"code":"forbidden","message":"Nested agents are disabled"}}"#, status: 403))
    let (screen, routes) = try await composer(server)
    defer { screen.close() }
    try await settle(screen, untilShowing: "mac · app")
    _ = try await typeAndStart(screen, server)
    try await settle(
      screen, untilShowing: "Nested agents are not available on this server.", contains: true)
    #expect(routes.opened.isEmpty)
  }

  @Test("A create whose first message fails opens the session and says setup didn't finish")
  func unfinishedSetupOpensAnyway() async throws {
    let server = nestedServer()
    server.route(
      "/v1/sessions/conv_new/events", method: "POST",
      .json(#"{"error":{"message":"no"}}"#, status: 400))
    let (screen, routes) = try await composer(server)
    defer { screen.close() }
    try await settle(screen, untilShowing: "mac · app")
    _ = try await typeAndStart(screen, server)
    try await settle(screen, until: "the session opens") { !routes.opened.isEmpty }
    #expect(routes.opened == ["conv_new"])
    #expect(routes.notices == [NestedComposer.setupNotice])
  }

  @Test("Without the capability the page says so and sends nothing")
  func capabilityOff() async throws {
    let server = nestedServer(siblings: false)
    let (screen, _) = try await composer(server)
    defer { screen.close() }
    try await settle(screen, untilShowing: "Nested agents are not available on this server.")
    #expect(server.requests("GET", "/v1/sessions/conv_src").isEmpty, "no source is read")
    #expect(!screen.allViews.contains { $0 is NSTextView }, "and no composer shows")
  }

  @Test("While the source loads the page says so, then the composer shows")
  func sourceLoading() async throws {
    let server = nestedServer()
    let gate = server.hold("/v1/sessions/conv_src")
    let (screen, _) = try await composer(server)
    defer { screen.close() }
    try await settle(screen, untilShowing: "Loading source session\u{2026}")
    gate.release()
    try await settle(screen, untilShowing: "A new conversation alongside Coordinator")
  }

  @Test("A source that can't be read offers a new session, which takes the draft")
  func sourceUnavailable() async throws {
    let server = nestedServer()
    let (screen, routes) = try await composer(
      server, sourceID: "conv_gone", drafts: ["conv_gone": "keep me"])
    let connection = routes.connection
    defer { screen.close() }
    try await settle(screen, untilShowing: "Source session is unavailable.")
    try screen.click(try center(of: "new-session-notice-action", in: screen))
    #expect(routes.continued == 1)
    let creation = try #require(connection.creation())
    #expect(creation.composerDrafts[""] == "keep me")

    let next = OffscreenWindow(
      NewSessionContainer(connection: connection, form: try isolatedForm()) { _ in },
      width: 900, height: 700)
    defer { next.close() }
    try await settle(next, until: "the new session's composer") {
      (next.allViews.first { $0 is NSTextView } as? NSTextView)?.string == "keep me"
    }
    #expect(creation.composerDrafts[""] == nil, "the draft is handed over once")
  }

  @Test("The source's draft stays with it, and each source has its own")
  func draftsScopedToTheSource() async throws {
    let server = nestedServer()
    let (screen, routes) = try await composer(server)
    let connection = routes.connection
    defer { screen.close() }
    try await settle(screen, untilShowing: "mac · app")
    let field = try #require(screen.allViews.first { $0 is NSTextView })
    try screen.click(field)
    try screen.type("plan")
    try await pause(screen)
    let creation = try #require(connection.creation())
    #expect(creation.composerDrafts["conv_src"] == "plan")
    #expect(creation.composerDrafts["conv_other"] == nil)
  }

  @Test("The Host menu offers only the source's host under a current-host policy")
  func hostMenuFollowsThePolicy() async throws {
    let (screen, _) = try await composer(nestedServer(policy: "current_host", sandboxes: true))
    defer { screen.close() }
    try await settle(screen, untilShowing: "mac · app")
    let menu = try await menu(
      screen, at: try center(of: "composer-host", in: screen), onceOffering: "mac")
    let titles = menuTitles(menu)
    #expect(!titles.contains("box"))
    #expect(!titles.contains { $0.contains("Sandbox") })
    #expect(!titles.contains("Connect new host\u{2026}"))
  }
}
