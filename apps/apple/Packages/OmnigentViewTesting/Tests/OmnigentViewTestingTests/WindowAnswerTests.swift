#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentViewTesting

  /// A button that asks to confirm: "Do it" is the dialog's first button and Cancel its second.
  private struct Confirming: View {
    @State private var isConfirming = false
    let log: (String) -> Void

    var body: some View {
      Button("Ask") { isConfirming = true }
        .confirmationDialog("Sure?", isPresented: $isConfirming) {
          Button("Do it") { log("done") }
        }
    }
  }

  /// A window that is never shown.
  @MainActor
  private func plainWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
  }

  @MainActor
  @Suite("A window's own alert and panel answers", .serialized, .timeLimit(.minutes(1)))
  struct WindowAnswerTests {
    init() {
      SystemSideEffects.install()
      SystemSideEffects.reset()
    }

    @Test("a window's answer reaches its dialog, and another window's dialog answers as usual")
    func dialogsByWindow() throws {
      var log: [String] = []
      let answered = OffscreenWindow(Confirming { log.append($0) }, width: 200, height: 100)
      let other = OffscreenWindow(Confirming { log.append($0) }, width: 200, height: 100)
      defer {
        answered.close()
        other.close()
      }
      SystemSideEffects.answer(alert: .alertSecondButtonReturn, for: answered.window)
      try answered.clickControl(at: 0)
      answered.settle(0.3)
      #expect(SystemSideEffects.record.alertMessages == ["Sure?"])
      #expect(log.isEmpty, "the window's answer is Cancel")

      try other.clickControl(at: 0)
      other.settle(0.3)
      #expect(SystemSideEffects.record.alertMessages == ["Sure?", "Sure?"])
      #expect(log == ["done"], "the other window answers with the first button")
    }

    @Test("sheets on a window, or on a sheet over it, answer as it says; the rest answer globally")
    func sheetsByWindow() {
      let screen = OffscreenWindow(Text("Page"), width: 300, height: 200)
      defer { screen.close() }
      let other = plainWindow()
      SystemSideEffects.answer(alert: .alertThirdButtonReturn, panel: .OK, for: screen.window)
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      var answers: [NSApplication.ModalResponse] = []
      NSAlert().beginSheetModal(for: screen.window) { answers.append($0) }
      NSAlert().beginSheetModal(for: other) { answers.append($0) }
      NSSavePanel().beginSheetModal(for: screen.window) { answers.append($0) }
      NSSavePanel().beginSheetModal(for: other) { answers.append($0) }
      #expect(answers == [.alertThirdButtonReturn, .alertSecondButtonReturn, .OK, .cancel])
      #expect(NSAlert().runModal() == .alertSecondButtonReturn, "an app-modal alert has no window")

      let sheet = plainWindow()
      screen.window.beginSheet(sheet)
      screen.settle()
      #expect(sheet.sheetParent === screen.window)
      NSAlert().beginSheetModal(for: sheet) { answers.append($0) }
      screen.window.endSheet(sheet)
      screen.settle()

      SystemSideEffects.reset()
      NSAlert().beginSheetModal(for: screen.window) { answers.append($0) }
      NSAlert().beginSheetModal(for: other) { answers.append($0) }
      #expect(
        Array(answers.dropFirst(4)) == [
          .alertThirdButtonReturn, .alertThirdButtonReturn, .alertFirstButtonReturn,
        ])
    }

    @Test("a window's answer goes away with the window")
    func answerEndsWithItsWindow() {
      weak var stored: SystemSideEffects.WindowAnswer?
      autoreleasepool {
        let window = plainWindow()
        SystemSideEffects.answer(alert: .alertSecondButtonReturn, for: window)
        stored = SystemSideEffects.windowAnswer(for: window)
        #expect(stored?.alert == .alertSecondButtonReturn)
        #expect(stored?.panel == .cancel)
      }
      #expect(stored == nil)
      #expect(SystemSideEffects.windowAnswer(for: nil) == nil)
    }
  }
#endif
