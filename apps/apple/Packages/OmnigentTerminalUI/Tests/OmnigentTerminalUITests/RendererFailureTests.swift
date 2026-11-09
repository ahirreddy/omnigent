import AppKit
import Foundation
import OmnigentGhosttyKit
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentTerminalUI

/// The renderer that cannot start.
@MainActor
private func refusingRuntime() throws(GhosttyError) -> GhosttyRuntime {
  throw .appCreationFailed
}

/// Creates a runtime when libghostty returns no app.
@MainActor
private func createRuntimeRefused() throws(GhosttyError) {
  _ = unsafe try GhosttyRuntime(appearance: .system()) { _, _ in nil }
}

/// Creates a surface when libghostty returns none.
@MainActor
private func createSurfaceRefused(_ connection: EchoTerminalConnection) throws(GhosttyError) {
  _ = unsafe try TerminalSurfaceController(connection: connection, runtime: nil) { _, _ in nil }
}

extension HostileConfigTests {
  @Test("configuration libghostty refuses comes back with its messages")
  func configRefused() {
    do {
      let config = try unsafe GhosttyRuntime.makeConfig(text: "no-such-setting = 1\n")
      unsafe ghostty_config_free(config)
      Issue.record("libghostty accepted an unknown setting")
    } catch {
      guard case .invalidConfiguration(let messages) = error else {
        Issue.record("wrong failure: \(error)")
        return
      }
      #expect(messages.contains { $0.contains("no-such-setting") })
    }
  }

  @Test("a runtime libghostty won't create says so")
  func runtimeCreationFails() {
    #expect(throws: GhosttyError.appCreationFailed) {
      try createRuntimeRefused()
    }
  }

  @Test("a surface libghostty won't create says so and never starts its connection")
  func surfaceCreationFails() {
    let connection = EchoTerminalConnection()
    #expect(throws: GhosttyError.surfaceCreationFailed) {
      try createSurfaceRefused(connection)
    }
    #expect(connection.state == .idle)
  }

  @Test("a missing recording says which file")
  func recordingIsMissing() {
    #expect(throws: ReplayTerminalConnection.RecordingError.missingResource("repl-tui.jsonl")) {
      _ = try ReplayTerminalConnection.recordedReplTUI(resources: Bundle(for: SilentResponder.self))
    }
  }

  @Test("a wakeup without a runtime does not crash, and one with a runtime ticks it")
  func wakeupWithoutRuntime() throws {
    GhosttyRuntime.tickAfterWakeup(from: refusingRuntime)
    let runtime = try GhosttyRuntime.shared()
    var asked = 0
    GhosttyRuntime.tickAfterWakeup(from: { () throws(GhosttyError) in
      asked += 1
      return runtime
    })
    #expect(asked == 1)
  }

  @Test("settings show why the renderer can't start, and a change isn't kept")
  func settingsWithoutRuntime() throws {
    SystemSideEffects.install()
    let screen = OffscreenWindow(
      TerminalSettingsView(runtimeSource: refusingRuntime), width: 600, height: 700)
    defer {
      screen.close()
      UserDefaults.standard.removeObject(forKey: TerminalPreferences.fontSizeKey)
    }
    screen.settle(0.3)
    let message = GhosttyError.appCreationFailed.description
    #expect(try screen.shows(message))

    let stepper = try #require(screen.allViews.first { $0 is NSStepper })
    let frame = stepper.convert(stepper.bounds, to: screen.host)
    try screen.click(CGPoint(x: frame.midX, y: frame.minY + 6))
    screen.settle()
    #expect(UserDefaults.standard.object(forKey: TerminalPreferences.fontSizeKey) == nil)
    #expect(try screen.shows(message))
  }

  @Test("a view that makes its own controller keeps the error when the surface can't be made")
  func holderKeepsFailure() {
    let holder = TerminalControllerHolder()
    holder.load(EchoTerminalConnection()) { _ throws(GhosttyError) in
      throw .surfaceCreationFailed
    }
    guard case .failure(.surfaceCreationFailed) = holder.result else {
      Issue.record("expected the failure, got \(String(describing: holder.result))")
      return
    }
  }

  @Test("a light or dark switch the runtime refuses shows on the surface; the old colors stay")
  func colorSwitchRefused() throws {
    let surface = try NeverShownSurface()
    let runtime = surface.controller.runtime
    let keep = unsafe runtime.makeNextConfig
    defer { unsafe runtime.makeNextConfig = keep }
    unsafe runtime.makeNextConfig = { _ throws(GhosttyError) in
      throw .invalidConfiguration(["refused"])
    }
    let before = runtime.appearance
    let opposite: ColorScheme = before.colorScheme == .dark ? .light : .dark
    let screen = OffscreenWindow(
      SessionTerminalView(controller: surface.controller).environment(\.colorScheme, opposite),
      width: 600, height: 400)
    defer { screen.close() }
    screen.settle(0.2)
    #expect(runtime.appearance == before)
    #expect(surface.controller.lastError?.contains("refused") == true)
  }
}

extension TerminalClipboardTests {
  @Test("the bell rings when a program sounds it")
  func bell() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    var rings = 0
    surface.view.ringBell = { rings += 1 }
    surface.connection.emit([0x07])
    #expect(await eventually { rings == 1 })
  }

  @Test("callbacks that arrive off the main thread are refused")
  func callbacksOffMain() async {
    let refusedRead = await Task.detached {
      ghosttyReadClipboard(nil, GHOSTTY_CLIPBOARD_STANDARD, nil)
    }.value
    #expect(!refusedRead)
    await Task.detached {
      ghosttyConfirmReadClipboard(nil, nil, nil, GHOSTTY_CLIPBOARD_REQUEST_PASTE)
      var content = unsafe ghostty_clipboard_content_s()
      unsafe ghosttyWriteClipboard(nil, GHOSTTY_CLIPBOARD_STANDARD, &content, 1, false)
    }.value
  }

  @Test("a clipboard write without contents, and a close request, change nothing")
  func emptyCallbacks() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    SystemSideEffects.reset()
    ghosttyWriteClipboard(nil, GHOSTTY_CLIPBOARD_STANDARD, nil, 0, false)
    ghosttyCloseSurface(nil, true)
    #expect(SystemSideEffects.pasteboard.string(forType: .string) == nil)
    #expect(surface.connection.state == .attached(readOnly: false))
  }
}
