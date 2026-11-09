import AppKit
import Foundation
import OmnigentGhosttyKit
import OmnigentViewTesting
import SwiftUI
import Testing

@testable import OmnigentTerminalUI

/// Runs a Ghostty action through the controller, as the runtime's callback does.
@MainActor
private func perform(
  _ tag: ghostty_action_tag_e, on controller: TerminalSurfaceController,
  configure: (inout ghostty_action_s) -> Void = { _ in }
) -> Bool {
  var action = unsafe ghostty_action_s()
  unsafe action.tag = tag
  unsafe configure(&action)
  return unsafe controller.handle(action: action)
}

/// Reports a link as Ghostty does: bytes and a length.
@MainActor
private func openLink(_ bytes: [UInt8], on controller: TerminalSurfaceController) -> Bool {
  bytes.withUnsafeBytes { raw in
    let text = unsafe raw.baseAddress?.assumingMemoryBound(to: CChar.self)
    return unsafe perform(GHOSTTY_ACTION_OPEN_URL, on: controller) { action in
      unsafe action.action.open_url.url = text
      unsafe action.action.open_url.len = UInt(bytes.count)
    }
  }
}

@Suite("Clipboard, selection and links through a real surface", .serialized)
struct TerminalClipboardTests {
  @Test("Copy puts the selection on the clipboard, with no consent banner")
  func copySelection() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    SystemSideEffects.reset()
    surface.controller.selectAll()
    #expect(surface.controller.hasSelection)
    surface.view.copy(nil)
    let copied = SystemSideEffects.pasteboard.string(forType: .string) ?? ""
    #expect(copied.contains("ready"))
    #expect(surface.controller.pendingClipboard == nil)
  }

  @Test("Paste types the clipboard into the program")
  func pasteClipboard() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    SystemSideEffects.reset()
    SystemSideEffects.pasteboard.setString("from-clipboard", forType: .string)
    surface.view.paste(nil)
    let expected = Array("from-clipboard".utf8)
    #expect(
      await eventually { surface.connection.received.suffix(expected.count) == expected[...] })
  }

  @Test("Paste with an empty clipboard sends the program nothing")
  func pasteNothing() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    SystemSideEffects.reset()
    surface.view.paste(nil)
    #expect(await surface.survives([], marker: "after-empty-paste"))
    #expect(surface.connection.received.isEmpty)
  }

  @Test("a multi-line paste the program did not ask for still arrives whole")
  func unsafePaste() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    SystemSideEffects.reset()
    SystemSideEffects.pasteboard.setString("first\nsecond", forType: .string)
    surface.view.paste(nil)
    #expect(await eventually { surface.connection.received == Array("first\rsecond".utf8) })
  }

  @Test("the consent banner's Copy puts the program's text on the clipboard; Ignore doesn't")
  func consentBanner() throws {
    let surface = try NeverShownSurface()
    SystemSideEffects.reset()
    surface.controller.remoteCopied("secret", policy: .ask)
    let pending = try #require(surface.controller.pendingClipboard)
    let screen = OffscreenWindow(
      ClipboardConsentBanner(controller: surface.controller, pending: pending).padding(),
      width: 460, height: 100)
    defer { screen.close() }
    screen.settle()
    #expect(SystemSideEffects.pasteboard.string(forType: .string) == nil)
    let controls = screen.controlFrames
    #expect(controls.count == 2)
    try screen.clickControl(at: 1)
    screen.settle()
    #expect(surface.controller.pendingClipboard == nil)
    #expect(SystemSideEffects.pasteboard.string(forType: .string) == nil)
    surface.controller.remoteCopied("secret", policy: .ask)
    try screen.clickControl(at: 0)
    screen.settle()
    #expect(surface.controller.pendingClipboard == nil)
    #expect(SystemSideEffects.pasteboard.string(forType: .string) == "secret")
    surface.controller.acceptPendingClipboard()
    #expect(SystemSideEffects.pasteboard.string(forType: .string) == "secret")
  }

  @Test("a copy Ghostty flags as remote asks; a user's copy goes straight to the clipboard")
  func copiedRouting() throws {
    let controller = try NeverShownSurface().controller
    SystemSideEffects.reset()
    controller.copied(text: "user", requiresConfirmation: false)
    #expect(SystemSideEffects.pasteboard.string(forType: .string) == "user")
    #expect(controller.pendingClipboard == nil)
    controller.remoteCopied("allowed", policy: .allow)
    #expect(SystemSideEffects.pasteboard.string(forType: .string) == "allowed")
    #expect(controller.pendingClipboard == nil)
    controller.copied(text: "remote", requiresConfirmation: true)
    #expect(SystemSideEffects.pasteboard.string(forType: .string) == "allowed")
    #expect(controller.pendingClipboard?.text == "remote")
  }

  @Test("web and mail links open; other schemes never reach the system")
  func links() {
    SystemSideEffects.install()
    SystemSideEffects.reset()
    #expect(TerminalLinks.open("https://example.com/a"))
    #expect(TerminalLinks.open("MAILTO:a@example.com"))
    #expect(!TerminalLinks.open("file:///etc/passwd"))
    #expect(!TerminalLinks.open("omnigent://evil"))
    #expect(
      SystemSideEffects.record.openedURLs.map(\.absoluteString) == [
        "https://example.com/a", "MAILTO:a@example.com",
      ])
  }

  @Test("a link Ghostty reports opens only when it is a web or valid link")
  func linkAction() throws {
    let controller = try NeverShownSurface().controller
    SystemSideEffects.reset()
    #expect(openLink(Array("https://example.com/x".utf8), on: controller))
    #expect(SystemSideEffects.record.openedURLs.map(\.absoluteString) == ["https://example.com/x"])

    #expect(!openLink([0xFF, 0xFE], on: controller))
    #expect(controller.lastError?.contains("not valid UTF-8") == true)
    let withoutURL = unsafe perform(GHOSTTY_ACTION_OPEN_URL, on: controller)
    #expect(!withoutURL)
    #expect(SystemSideEffects.record.openedURLs.count == 1)
  }

  @Test("Ghostty's other actions: a render request is taken and an unknown one isn't")
  func otherActions() throws {
    let controller = try NeverShownSurface().controller
    _ = unsafe perform(GHOSTTY_ACTION_RENDER, on: controller)
    let unknown = unsafe perform(GHOSTTY_ACTION_NEW_TAB, on: controller)
    #expect(!unknown)
  }
}
