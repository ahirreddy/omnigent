#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentAppUI

  /// A view that takes the keyboard, as a composer does.
  private struct KeyboardTarget: NSViewRepresentable {
    final class TargetView: NSView {
      override var acceptsFirstResponder: Bool { true }
    }

    func makeNSView(context: Context) -> TargetView { TargetView() }
    func updateNSView(_ view: TargetView, context: Context) {}
  }

  @Suite("A window under its Settings page", .serialized, .timeLimit(.minutes(1)))
  @MainActor
  struct SettingsWindowTakeoverTests {
    private let navigator = SettingsNavigator()

    @Test("the page takes the keyboard from the content, and gives it back on leaving")
    func keyboard() throws {
      SystemSideEffects.reset()
      let navigator = navigator
      let screen = OffscreenWindow(
        KeyboardTarget().settingsPage(navigator) {
          Text(verbatim: "Settings page")
        },
        width: 400, height: 300)
      defer { screen.close() }
      let target = try #require(
        screen.allViews.first { $0 is KeyboardTarget.TargetView })
      #expect(screen.window.makeFirstResponder(target))

      navigator.open()
      screen.settle()
      #expect(screen.window.firstResponder === screen.window)
      navigator.close()
      screen.settle()
      #expect(screen.window.firstResponder === target)

      // Nothing had the keyboard: leaving gives it to nothing.
      #expect(screen.window.makeFirstResponder(nil))
      navigator.open()
      screen.settle()
      navigator.close()
      screen.settle()
      #expect(screen.window.firstResponder === screen.window)
    }

    /// A window under a plain Settings page, as the content left it: titled, with a toolbar.
    private func titledWindow() -> OffscreenWindow<some View> {
      SystemSideEffects.reset()
      let navigator = navigator
      let screen = OffscreenWindow(
        Text(verbatim: "Content").settingsPage(navigator) { Text(verbatim: "Settings page") },
        width: 400, height: 300)
      // Only a window with a title bar keeps a toolbar.
      screen.window.styleMask.insert(.titled)
      screen.window.title = "Project notes"
      screen.window.toolbar = NSToolbar(identifier: "settings-host-\(UUID().uuidString)")
      return screen
    }

    @Test("the window is titled Settings while the page shows, then as the content titles it")
    func title() throws {
      let screen = titledWindow()
      defer { screen.close() }
      screen.window.subtitle = "Working"
      navigator.open()
      screen.settle()
      #expect(screen.window.title == "Settings" && screen.window.subtitle.isEmpty)
      // The covered content renames the window under the page: its turn ended.
      screen.window.title = "Project notes, renamed"
      screen.window.subtitle = "Ready"
      #expect(screen.window.title == "Settings" && screen.window.subtitle.isEmpty)
      navigator.close()
      screen.settle()
      #expect(screen.window.title == "Project notes, renamed")
      #expect(screen.window.subtitle == "Ready")
    }

    @Test("a window its content happens to call Settings keeps that name after the page")
    func ownTitleKept() throws {
      let screen = titledWindow()
      defer { screen.close() }
      screen.window.title = "Settings"
      navigator.open()
      screen.settle()
      navigator.close()
      screen.settle()
      #expect(screen.window.title == "Settings")
    }

    @Test("the covered content's toolbar is hidden under the page, a new one too, then shown")
    func toolbar() throws {
      let screen = titledWindow()
      defer { screen.close() }
      let first = try #require(screen.window.toolbar)
      first.autosavesConfiguration = true
      // AppKit keeps a saving toolbar's state under its identifier; the test leaves none.
      defer {
        UserDefaults.standard.removeObject(forKey: "NSToolbar Configuration \(first.identifier)")
      }
      navigator.open()
      screen.settle()
      #expect(!first.isVisible)
      #expect(!first.autosavesConfiguration, "a quit from Settings must not save it hidden")
      navigator.close()
      screen.settle()
      #expect(first.isVisible && first.autosavesConfiguration)

      navigator.open()
      screen.settle()
      #expect(!first.isVisible)
      // The covered content swaps its toolbar under the page: its tabs changed.
      let second = NSToolbar(identifier: "settings-host-\(UUID().uuidString)")
      screen.window.toolbar = second
      #expect(!second.isVisible)
      navigator.close()
      screen.settle()
      #expect(second.isVisible, "the window's toolbar shows again")
      #expect(first.autosavesConfiguration && !second.autosavesConfiguration)
    }

    @Test("a toolbar the person hid stays hidden after Settings")
    func hiddenToolbarStaysHidden() throws {
      let screen = titledWindow()
      defer { screen.close() }
      let toolbar = try #require(screen.window.toolbar)
      toolbar.isVisible = false
      navigator.open()
      screen.settle()
      navigator.close()
      screen.settle()
      #expect(!toolbar.isVisible)
    }
  }
#endif
