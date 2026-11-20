import SwiftUI

#if os(macOS)
  import AppKit

  /// Takes Escape in this window while `isActive` (a file fills the window in full screen), so
  /// it leaves full screen wherever the user clicked last, as the web's file viewer does. An
  /// editable text view keeps its own Escape.
  struct FullScreenEscapeWatcher: NSViewRepresentable {
    let isActive: Bool
    let exit: @MainActor () -> Void

    func makeNSView(context: Context) -> WatcherView { WatcherView() }

    func updateNSView(_ view: WatcherView, context: Context) {
      view.isActive = isActive
      view.exit = exit
    }

    static func dismantleNSView(_ view: WatcherView, coordinator: ()) {
      view.stop()
    }

    final class WatcherView: NSView {
      /// The Escape key's virtual key code.
      static let escapeKeyCode: UInt16 = 53

      var isActive = false
      var exit: (@MainActor () -> Void)?
      private var monitor: Any?

      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        // AppKit declares `window` unowned(unsafe); it is only compared here, never retained.
        guard unsafe window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
          guard let self, unsafe event.window === self.window,
            self.handle(
              keyCode: event.keyCode, modifiers: event.modifierFlags,
              responder: unsafe self.window?.firstResponder)
          else { return event }
          return nil
        }
      }

      func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
      }

      /// Leaves full screen for a bare Escape while active, unless an editable text view has
      /// the keyboard (a find field or an editor, whose Escape is its own).
      /// - Returns: Whether the key was used.
      func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, responder: NSResponder?)
        -> Bool
      {
        guard isActive, let exit, Self.isBareEscape(keyCode: keyCode, modifiers: modifiers),
          !Self.isEditing(responder)
        else { return false }
        exit()
        return true
      }

      /// Escape with no modifier.
      static func isBareEscape(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == escapeKeyCode
          && modifiers.isDisjoint(with: [.shift, .command, .control, .option])
      }

      /// The keyboard is in editable text: a text view or a field's editor.
      static func isEditing(_ responder: NSResponder?) -> Bool {
        guard let textView = responder as? NSTextView else { return false }
        return textView.isEditable
      }
    }
  }
#endif

extension View {
  /// On the Mac, Escape runs `exit` while `isActive`, ahead of the focused view; elsewhere this
  /// does nothing (touch layouts have no workspace full screen).
  func fullScreenEscape(isActive: Bool, exit: @escaping @MainActor () -> Void) -> some View {
    #if os(macOS)
      background { FullScreenEscapeWatcher(isActive: isActive, exit: exit) }
    #else
      self
    #endif
  }
}
