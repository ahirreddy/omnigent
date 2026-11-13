import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import SwiftUI
import Testing

@testable import OmnigentAppUI

/// Where the palette asked Settings to open.
@MainActor
private final class OpenedSettings {
  var destinations: [SettingsDestination] = []
}

/// The palette over a connected window's stores, with a button that opens it as Command-K does.
private struct PaletteWindow: View {
  let session: ServerSession
  let selection: WindowSelection
  let opened: OpenedSettings

  var body: some View {
    PaletteOpenButton()
      .modifier(PaletteAdapter(session: session, selection: selection.binding))
      .environment(
        \.openSettingsAt, OpenSettingsDestinationAction { opened.destinations.append($0) })
  }
}

private struct PaletteOpenButton: View {
  @Environment(\.openCommandPalette) private var open

  var body: some View {
    Button("Open") { open?() }
  }
}

/// Commands typed into the presented palette and run with Return, down to what the window does.
@MainActor
@Suite("Palette, typed in a connected window", .serialized, .timeLimit(.minutes(1)))
struct PaletteTypedTests {
  private func palette(
    _ session: ServerSession, _ selection: WindowSelection, _ opened: OpenedSettings
  ) throws -> OffscreenWindow<PaletteWindow> {
    let screen = OffscreenWindow(
      PaletteWindow(session: session, selection: selection, opened: opened), width: 640,
      height: 560)
    try screen.clickControl(at: 0)
    #expect(screen.window.attachedSheet != nil)
    return screen
  }

  /// Types a command and runs it; the window acts once the palette has closed.
  private func run(
    _ query: String, in screen: OffscreenWindow<PaletteWindow>, until done: () -> Bool
  ) async throws {
    try screen.type(query)
    try screen.press(keyCode: 36, characters: "\r")
    try await settle(screen, until: "\(query) to run") {
      screen.window.attachedSheet == nil && done()
    }
  }

  @Test("Go to Settings opens the Settings window on General")
  func settings() async throws {
    let session = try await signedInSession(threeSessionServer())
    let selection = WindowSelection(.inbox)
    let opened = OpenedSettings()
    let screen = try palette(session, selection, opened)
    defer { screen.close() }
    try await run("go to settings", in: screen) { !opened.destinations.isEmpty }
    #expect(opened.destinations == [.tab(SettingsNavigator.generalTab)])
    #expect(selection.page == .inbox, "the window stays on its page")
  }

  @Test("Go to next session that needs you opens the first session waiting")
  func nextRequest() async throws {
    let session = try await connectedDemo()
    try await eventually("waiting sessions") {
      session.connection.sessionList.needsResponse.count == 2
    }
    let waiting = session.connection.sessionList.needsResponse.map(\.id)
    let selection = WindowSelection()
    let screen = try palette(session, selection, OpenedSettings())
    defer { screen.close() }
    try await run("next session that needs", in: screen) { selection.page != nil }
    #expect(selection.page == .session(waiting[0]))
  }

  @Test(
    "Go to Automations and Go to Usage open those pages on a server that offers them",
    arguments: [
      ("go to automations", SidebarDestination.automations), ("go to usage", .usage),
    ])
  func offeredPages(query: String, page: SidebarDestination) async throws {
    let server = threeSessionServer()
    let session = try await signedInSession(server)
    server.route(
      "/v1/info",
      .json(#"{"single_user":true,"automations_enabled":true,"features":{"usage_page":true}}"#))
    _ = await session.connection.pages?.loadOffered()
    let selection = WindowSelection()
    let screen = try palette(session, selection, OpenedSettings())
    defer { screen.close() }
    try await run(query, in: screen) { selection.page != nil }
    #expect(selection.page == page)
  }
}
