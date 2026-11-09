import AppKit
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentTerminalUI

/// Counts retries from the overlay's button.
@MainActor
private final class RetryCounter {
  var count = 0
}

@MainActor
private func overlay(_ state: TerminalConnectionState, retries: RetryCounter = RetryCounter())
  -> OffscreenWindow<TerminalStatusOverlay>
{
  SystemSideEffects.install()
  let screen = OffscreenWindow(
    TerminalStatusOverlay(state: state) { retries.count += 1 }, width: 500, height: 320)
  screen.settle()
  return screen
}

@Suite("The dead-terminal card and connection status", .serialized)
struct TerminalStatusOverlayTests {
  @Test("a shell that's gone says so and offers Reattach")
  func shellGone() throws {
    let retries = RetryCounter()
    let failure = TerminalFailure(message: "runner attach factory failed: no process")
    let screen = overlay(.failed(failure), retries: retries)
    defer { screen.close() }
    let shown = try screen.shownText()
    #expect(shown.contains("This terminal isn't running"))
    #expect(!shown.contains { $0.contains("runner attach factory") })
    #expect(screen.controlFrames.count == 1)
    try screen.clickControl(at: 0)
    #expect(retries.count == 1)
  }

  @Test("a failed connection shows its reason and retries")
  func connectionFailed() throws {
    let retries = RetryCounter()
    let screen = overlay(.failed(TerminalFailure(message: "boom")), retries: retries)
    defer { screen.close() }
    let shown = try screen.shownText()
    #expect(shown.contains("Terminal connection failed"))
    #expect(shown.contains("boom"))
    try screen.clickControl(at: 0)
    #expect(retries.count == 1)
  }

  @Test("an expired sign-in asks to sign in and doesn't offer a retry that can't work")
  func signInRequired() throws {
    let screen = overlay(.failed(TerminalFailure(message: "401", requiresSignIn: true)))
    defer { screen.close() }
    #expect(try screen.shows("Sign in again"))
    #expect(screen.controlFrames.isEmpty)
  }

  @Test("each way a terminal closes has its own title and detail, and can be reattached")
  func closedCards() throws {
    let cases: [(TerminalCloseReason, [String])] = [
      (.terminalEnded(reason: ""), ["Terminal ended", "The terminal's program exited."]),
      (.terminalEnded(reason: "exit 3"), ["Terminal ended", "exit 3"]),
      (
        .detached(reason: ""),
        ["Terminal detached", "The terminal is still running. Reattach to continue."]
      ),
      (.detached(reason: "kicked"), ["Terminal detached", "kicked"]),
      (
        .serverClosed(code: 1011, reason: ""),
        ["Connection closed", "The server closed the terminal (code 1011)."]
      ),
      (.serverClosed(code: 1000, reason: "bye"), ["Connection closed", "bye (code 1000)"]),
      (.stopped, ["Disconnected", "You detached from this terminal."]),
    ]
    for (reason, lines) in cases {
      let retries = RetryCounter()
      let screen = overlay(.closed(reason), retries: retries)
      defer { screen.close() }
      let shown = try screen.shownText()
      #expect(lines.allSatisfy(shown.contains), "\(reason)")
      try screen.clickControl(at: 0)
      #expect(retries.count == 1, "\(reason)")
    }
  }

  @Test("reconnecting counts down in whole seconds, and says only that when it's immediate")
  func reconnecting() throws {
    let waiting = overlay(.reconnecting(failures: 2, retryInMilliseconds: 1500, reason: "lost"))
    defer { waiting.close() }
    #expect(try waiting.shows("Connection lost (lost). Retrying in 2s…"))
    let now = overlay(.reconnecting(failures: 1, retryInMilliseconds: 0, reason: "lost"))
    defer { now.close() }
    #expect(try now.shows("Reconnecting…"))
    #expect(try !now.shows("Retrying"))
  }

  @Test("connecting shows progress; attached and idle draw nothing over the terminal")
  func quietStates() throws {
    let connecting = overlay(.connecting)
    defer { connecting.close() }
    #expect(try connecting.shows("Connecting…"))
    for state in [TerminalConnectionState.idle, .attached(readOnly: false)] {
      let screen = overlay(state)
      defer { screen.close() }
      #expect(try screen.shownText().isEmpty, "\(state)")
    }
  }
}

@Suite("Find in the terminal", .serialized)
struct TerminalFindBarTests {
  private func findBar(_ controller: TerminalSurfaceController)
    -> OffscreenWindow<TerminalFindBar>
  {
    let screen = OffscreenWindow(TerminalFindBar(controller: controller), width: 460, height: 80)
    screen.settle()
    return screen
  }

  @Test("the bar counts matches, moves with its buttons and Return, and Close ends the search")
  func findBarControls() async throws {
    let surface = try NeverShownSurface()
    let controller = surface.controller
    #expect(await surface.ready())
    controller.feed(Array("needle one\r\nneedle two\r\nneedle three\r\n".utf8))
    await Task.yield()
    #expect(await eventually { controller.visibleText().contains("needle three") })
    controller.startSearch()
    let screen = findBar(controller)
    defer { screen.close() }

    try screen.type("needle")
    screen.settle()
    #expect(controller.search?.needle == "needle")
    #expect(await eventually { controller.search?.total == 3 })
    screen.settle()
    #expect(try screen.shows("3 matches"))

    // Down, then Return: each moves on, and the label says where.
    try screen.clickControl(at: 1)
    #expect(await eventually { controller.search?.selected != nil })
    screen.settle()
    let first = try #require(controller.search?.selected)
    #expect(try screen.shows("\(first + 1) of 3"))
    try screen.press(keyCode: 36, characters: "\r")
    #expect(await eventually { controller.search?.selected != first })
    let second = try #require(controller.search?.selected)
    try screen.clickControl(at: 0)
    #expect(await eventually { controller.search?.selected != second })

    try screen.clickControl(at: 2)
    #expect(await eventually { controller.search == nil })
  }

  @Test("a find bar that reappears, as on switching tabs and back, keeps its count and needle")
  func reappearingBar() async throws {
    let surface = try NeverShownSurface()
    let controller = surface.controller
    #expect(await surface.ready())
    controller.startSearch()
    controller.updateSearch("absent-text")
    #expect(await eventually { controller.search?.total == 0 })
    let screen = findBar(controller)
    defer { screen.close() }
    screen.settle()
    #expect(controller.search?.total == 0)
    #expect(try screen.shows("No matches"))
    #expect(screen.allViews.contains { ($0 as? NSTextField)?.stringValue == "absent-text" })
  }
}
