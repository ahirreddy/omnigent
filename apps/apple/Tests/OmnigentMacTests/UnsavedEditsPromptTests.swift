import AppKit
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// The question before unsaved edits are lost. Building an alert shows nothing.
@MainActor
struct UnsavedEditsAlertTests {
  @Test func oneFileIsNamedInTheQuestion() {
    let alert = UnsavedEditsAlert.alert(for: ["/work/src/main.rs"])
    #expect(alert.messageText == "Save changes to \u{201C}main.rs\u{201D}?")
    #expect(!alert.informativeText.contains("/work/src/main.rs"))
  }

  @Test func severalFilesAreCountedAndListed() {
    let alert = UnsavedEditsAlert.alert(for: ["/work/a.rs", "/work/b.rs"])
    #expect(alert.messageText == "Save changes to 2 files?")
    #expect(alert.informativeText.contains("/work/a.rs\n/work/b.rs"))
  }

  @Test func theButtonsAnswerSaveDiscardAndCancel() {
    let buttons = UnsavedEditsAlert.alert(for: ["/a"]).buttons
    #expect(buttons.map(\.title) == ["Save", "Don't Save", "Cancel"])
    #expect(buttons[1].hasDestructiveAction)
    #expect(buttons[2].keyEquivalent == "\u{1b}")
    #expect(UnsavedEditsAlert.choice(.alertFirstButtonReturn) == .save)
    #expect(UnsavedEditsAlert.choice(.alertSecondButtonReturn) == .discard)
    #expect(UnsavedEditsAlert.choice(.alertThirdButtonReturn) == .cancel)
    #expect(UnsavedEditsAlert.choice(.cancel) == .cancel)
  }
}

/// Closing asks nothing when there is nothing to lose. Neither case shows a window or a sheet.
@MainActor
struct UnsavedEditsCloseWithoutPromptTests {
  private final class VetoingDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool { false }
  }

  private func offscreenWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled, .closable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
  }

  @Test func aWindowWithoutEditsClosesWithoutAsking() {
    var asked = 0
    let guardian = UnsavedEditsWindowGuard(
      unsaved: {
        asked += 1
        return []
      }, save: { [] }, discard: {})
    let window = offscreenWindow()
    #expect(guardian.windowShouldClose(window))
    #expect(asked == 1)
    #expect(window.attachedSheet == nil)
  }

  @Test func theOriginalDelegatesVetoWinsBeforeTheEditsAreRead() {
    var asked = 0
    let guardian = UnsavedEditsWindowGuard(
      unsaved: {
        asked += 1
        return ["/a"]
      }, save: { [] }, discard: {})
    let window = offscreenWindow()
    let original = VetoingDelegate()
    window.delegate = original
    guardian.install(on: window)
    #expect(!guardian.windowShouldClose(window))
    #expect(asked == 0)
    #expect(window.attachedSheet == nil)
  }
}

/// Each answer to the sheet. A sheet needs a window on screen, so these run only in a VM
/// (`vm-test.sh`), never on a developer's Mac.
@MainActor
@Suite("Unsaved edits sheet", .enabled(if: VirtualMachine.isPresent), .serialized)
struct UnsavedEditsSheetTests {
  /// What a close did to the edits.
  private final class Calls {
    var saves = 0
    var discards = 0
  }

  private let calls = Calls()

  private func shownWindow(savesLeaving left: [String] = []) -> (NSWindow, UnsavedEditsWindowGuard)
  {
    let window = NSWindow(
      contentRect: CGRect(x: 100, y: 100, width: 400, height: 300),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let calls = calls
    let guardian = UnsavedEditsWindowGuard(
      unsaved: { ["/work/a.rs"] },
      save: {
        calls.saves += 1
        return left
      },
      discard: { calls.discards += 1 })
    guardian.install(on: window)
    window.orderFront(nil)
    return (window, guardian)
  }

  /// Asks to close, then answers the sheet.
  private func close(_ window: NSWindow, answering answer: NSApplication.ModalResponse) async throws
  {
    window.performClose(nil)
    try await waitFor { window.attachedSheet != nil }
    #expect(window.isVisible, "the window closed before the question was answered")
    let sheet = try #require(window.attachedSheet)
    window.endSheet(sheet, returnCode: answer)
  }

  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
  }

  @Test func cancelKeepsTheWindowAndTheEdits() async throws {
    let (window, guardian) = shownWindow()
    defer {
      guardian.uninstall()
      window.close()
    }
    try await close(window, answering: .alertThirdButtonReturn)
    try await waitFor { window.attachedSheet == nil }
    #expect(window.isVisible)
    #expect(calls.saves == 0)
    #expect(calls.discards == 0)
  }

  @Test func dontSaveDiscardsAndCloses() async throws {
    let (window, guardian) = shownWindow()
    defer {
      guardian.uninstall()
      window.close()
    }
    try await close(window, answering: .alertSecondButtonReturn)
    try await waitFor { !window.isVisible }
    #expect(calls.discards == 1)
    #expect(calls.saves == 0)
  }

  @Test func saveClosesOnceEverythingIsSaved() async throws {
    let (window, guardian) = shownWindow()
    defer {
      guardian.uninstall()
      window.close()
    }
    try await close(window, answering: .alertFirstButtonReturn)
    try await waitFor { !window.isVisible }
    #expect(calls.saves == 1)
    #expect(calls.discards == 0)
  }

  @Test func aFailedSaveKeepsTheWindowAndSaysWhich() async throws {
    let (window, guardian) = shownWindow(savesLeaving: ["/work/a.rs"])
    defer {
      if let sheet = window.attachedSheet { window.endSheet(sheet) }
      guardian.uninstall()
      window.close()
    }
    try await close(window, answering: .alertFirstButtonReturn)
    try await waitFor { calls.saves == 1 && window.attachedSheet != nil }
    #expect(window.isVisible)
    #expect(calls.discards == 0)
    let failure = window.attachedSheet.flatMap { sheet in
      sheet.contentView?.deepTexts().joined(separator: "\n")
    }
    #expect(failure?.contains("/work/a.rs") == true)
  }
}

extension NSView {
  /// The text of every label in this view and those inside it.
  fileprivate func deepTexts() -> [String] {
    let own = (self as? NSTextField).map { [$0.stringValue] } ?? []
    return own + subviews.flatMap { $0.deepTexts() }
  }
}
