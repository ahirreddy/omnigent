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

/// A mounted window's page and its server session.
@MainActor
private struct NestedWindow {
  let selection: WindowSelection
  let session: ServerSession
}

/// Where Add nested agent starts in the window: first in a session row's menu, gated on the
/// server's capability and on the viewer owning the session; choosing it opens the composer.
@MainActor
@Suite("Add nested agent entry points", .serialized, .timeLimit(.minutes(1)))
struct NestedAgentEntryTests {
  /// The connected window over `server`, once the server's pages are read.
  private func window(
    _ server: AppServer
  ) async throws -> (OffscreenWindow<ConnectedServerView>, NestedWindow) {
    let session = try await signedInSession(server)
    let selection = WindowSelection()
    let view = ConnectedServerView(
      session: session, selection: selection.binding, sidebar: SidebarModel(),
      opener: ExternalURLOpener { _ in true }, openInNewWindow: nil, serverSwitching: nil)
    let screen = OffscreenWindow(view, width: 1200, height: 800)
    try await settle(screen, until: "the server's pages") {
      session.connection.pages?.offered != nil
    }
    try await pause(screen, .milliseconds(150))
    return (screen, NestedWindow(selection: selection, session: session))
  }

  /// The context menu of the window's one session row.
  private func sessionMenu(_ screen: OffscreenWindow<ConnectedServerView>) throws -> NSMenu {
    let list = try #require(screen.allViews.lazy.compactMap { $0 as? NSTableView }.first)
    for row in 0..<list.numberOfRows {
      if let menu = try? contextMenu(ofListRow: row, in: screen),
        menu.items.contains(where: { $0.title == "Copy Session ID" })
      {
        return menu
      }
    }
    throw OffscreenWindowError.notFound("a session row's menu")
  }

  @Test("It leads an owned session's menu and opens the composer beside that session")
  func ownedSessionOpensTheComposer() async throws {
    let (screen, mounted) = try await window(nestedServer())
    let selection = mounted.selection
    defer { screen.close() }
    let menu = try sessionMenu(screen)
    #expect(menu.items.first?.title == "Add nested agent")
    #expect(menu.items.dropFirst().first?.isSeparatorItem == true)
    try screen.choose("Add nested agent", in: menu)
    #expect(selection.page == .nestedSession(sourceID: "conv_src"))
    try await settle(screen, untilShowing: "A new conversation alongside Coordinator")
    #expect(try screen.shows("Add nested agent"))
  }

  @Test("A server without nested agents doesn't offer it")
  func capabilityOff() async throws {
    let (screen, mounted) = try await window(nestedServer(siblings: false))
    let session = mounted.session
    defer { screen.close() }
    #expect(!menuTitles(try sessionMenu(screen)).contains("Add nested agent"))
    #expect(!NestedAgentGate.offered(session.connection))
  }

  @Test("A session someone else shared isn't offered it")
  func sharedSession() async throws {
    let server = nestedServer()
    let shared = String(nestedSourceRow.dropLast()) + #","owner":"alice"}"#
    server.route(
      "/v1/sessions", method: "GET",
      .json(#"{"object":"list","data":[\#(shared)],"has_more":false}"#))
    let (screen, _) = try await window(server)
    defer { screen.close() }
    #expect(!menuTitles(try sessionMenu(screen)).contains("Add nested agent"))
  }

  @Test("A failed setup opens the new session under a notice")
  func unfinishedSetupNotice() async throws {
    let server = nestedServer()
    server.route(
      "/v1/sessions/conv_new/events", method: "POST",
      .json(#"{"error":{"message":"no"}}"#, status: 400))
    let (screen, mounted) = try await window(server)
    let selection = mounted.selection
    let session = mounted.session
    defer { screen.close() }
    selection.page = .nestedSession(sourceID: "conv_src")
    try await settle(screen, untilShowing: "A new conversation alongside Coordinator")
    let field = try #require(screen.allViews.first { $0 is NSTextView })
    try screen.click(field)
    try screen.type("hello")
    try screen.press(keyCode: 36, characters: "\r")
    try await settle(screen, until: "the new session") { selection.page == .session("conv_new") }
    try await settle(screen, untilShowing: NestedComposer.setupNotice)
    #expect(session.connection.creation()?.phase == .editing)
  }

  @Test("Continue in a new session leaves for the new-session page")
  func continueInANewSession() async throws {
    let (screen, mounted) = try await window(nestedServer())
    let selection = mounted.selection
    defer { screen.close() }
    selection.page = .nestedSession(sourceID: "conv_gone")
    try await settle(screen, untilShowing: "Source session is unavailable.")
    try screen.click(try center(of: "new-session-notice-action", in: screen))
    #expect(selection.page == .newSession)
  }
}
