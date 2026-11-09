import AppKit
import Foundation
import OmnigentUIComponents
import OmnigentViewTesting
import SwiftUI
import Testing

@testable import OmnigentAppUI

/// The keyboard follows a terminal tab: opening or selecting one puts typing in its terminal.
@MainActor
@Suite("Terminal tab keyboard focus", .serialized, .timeLimit(.minutes(1)))
struct TerminalTabFocusTests {
  private typealias Screen = OffscreenWindow<AppWindowRoot>

  private let terminal = AppTabContent.terminal(sessionID: "demo-design", terminalID: "t1")

  /// The demo's design session in a window, its chat shown.
  private func window() async throws -> (Screen, ServerSession) {
    let session = try await connectedDemo()
    let selection = WindowSelection(.session("demo-design"))
    let screen = OffscreenWindow(
      AppWindowRoot(session: session, selection: selection), width: 1200, height: 800)
    try await pause(screen, .milliseconds(300))
    return (screen, session)
  }

  /// Whether the window's keyboard is in a terminal surface.
  private func terminalHasKeyboard(_ screen: Screen) -> Bool {
    screen.window.firstResponder.map { String(describing: type(of: $0)) }
      == "TerminalSurfaceNSView"
  }

  @Test("Opening a terminal tab puts the keyboard in its terminal")
  func openingATerminal() async throws {
    let (screen, session) = try await window()
    defer { screen.close() }
    #expect(!terminalHasKeyboard(screen))
    session.tabs.current?.open(terminal)
    try await settle(screen, until: "the terminal to take the keyboard") {
      terminalHasKeyboard(screen)
    }
  }

  @Test("Selecting a terminal tab again puts the keyboard back in it")
  func selectingATerminalAgain() async throws {
    let (screen, session) = try await window()
    defer { screen.close() }
    let tabs = try #require(session.tabs.current)
    let chat = try #require(tabs.tabs.first)
    let shell = tabs.open(terminal)
    try await settle(screen, until: "the terminal to take the keyboard") {
      terminalHasKeyboard(screen)
    }
    tabs.select(chat.id)
    try await pause(screen, .milliseconds(300))
    #expect(!terminalHasKeyboard(screen))
    tabs.select(shell.id)
    try await settle(screen, until: "the terminal to take the keyboard back") {
      terminalHasKeyboard(screen)
    }
  }

  @Test("A terminal tab left before it takes the keyboard leaves it with the shown tab")
  func leftBeforeFocus() async throws {
    let (screen, session) = try await window()
    defer { screen.close() }
    let tabs = try #require(session.tabs.current)
    let chat = try #require(tabs.tabs.first)
    tabs.open(terminal)
    try await pause(screen, .milliseconds(30))
    tabs.select(chat.id)
    try await pause(screen, .milliseconds(400))
    #expect(tabs.selected?.id == chat.id)
    #expect(!terminalHasKeyboard(screen))
  }
}
