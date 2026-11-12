import SwiftUI

#if os(macOS)
  import AppKit

  /// Turns Shift-Tab into `perform` while `isActive` (the composer's editor has focus in this
  /// window). AppKit moves the keyboard focus on Shift-Tab before the editor's own key presses
  /// see it, so the key is taken on its way in.
  struct ShiftTabWatcher: NSViewRepresentable {
    let isActive: Bool
    /// Returns whether it used the key; an unused one goes on to move the focus.
    let perform: @MainActor () -> Bool

    func makeNSView(context: Context) -> WatcherView { WatcherView() }

    func updateNSView(_ view: WatcherView, context: Context) {
      view.isActive = isActive
      view.perform = perform
    }

    static func dismantleNSView(_ view: WatcherView, coordinator: ()) {
      view.stop()
    }

    final class WatcherView: NSView {
      /// The Tab key's virtual key code.
      static let tabKeyCode: UInt16 = 48

      var isActive = false
      var perform: (@MainActor () -> Bool)?
      private var monitor: Any?

      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        // AppKit declares `window` unowned(unsafe); it is only compared here, never retained.
        guard unsafe window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
          guard let self, unsafe event.window === self.window, self.handle(event) else {
            return event
          }
          return nil
        }
      }

      func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
      }

      /// Runs `perform` for a Shift-Tab while active.
      /// - Returns: Whether the key was used.
      func handle(_ event: NSEvent) -> Bool {
        guard isActive, let perform,
          Self.isShiftTab(keyCode: event.keyCode, modifiers: event.modifierFlags)
        else { return false }
        return perform()
      }

      /// Tab with Shift and no other modifier, whatever character the keyboard sends for it.
      static func isShiftTab(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let held = modifiers.intersection([.shift, .command, .control, .option])
        return keyCode == tabKeyCode && held == .shift
      }
    }
  }
#endif

extension View {
  /// On the Mac, Shift-Tab runs `perform` while `isActive`, ahead of keyboard focus navigation;
  /// elsewhere the editor's own key presses deliver it.
  func shiftTabKey(isActive: Bool, perform: @escaping @MainActor () -> Bool) -> some View {
    #if os(macOS)
      background { ShiftTabWatcher(isActive: isActive, perform: perform) }
    #else
      self
    #endif
  }
}
