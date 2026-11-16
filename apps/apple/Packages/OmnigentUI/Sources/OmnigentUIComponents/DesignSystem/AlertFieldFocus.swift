import SwiftUI

#if os(macOS)
  import AppKit

  /// Gives a SwiftUI alert's text field the keyboard once the alert is up. With keyboard
  /// navigation on, AppKit opens the alert with Cancel focused, so typing missed the field.
  struct AlertFieldFocus: NSViewRepresentable {
    let isPresented: Bool

    func makeNSView(context: Context) -> FocusView { FocusView() }

    func updateNSView(_ view: FocusView, context: Context) {
      view.isPresented = isPresented
    }

    static func dismantleNSView(_ view: FocusView, coordinator: ()) {
      view.stopWatching()
    }

    final class FocusView: NSView {
      var isPresented = false {
        didSet {
          guard isPresented != oldValue else { return }
          if isPresented { watch() } else { stopWatching() }
        }
      }
      private var observer: (any NSObjectProtocol)?

      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopWatching()
        if isPresented { watch() }
      }

      /// Focuses the field of the alert this window shows now, or of the next one it begins.
      private func watch() {
        // AppKit declares `window` unowned(unsafe); it is only compared here, never retained.
        guard observer == nil, let window = unsafe window else { return }
        observer = NotificationCenter.default.addObserver(
          forName: NSWindow.willBeginSheetNotification, object: window, queue: .main
        ) { [weak self] _ in
          // The sheet is attached once `beginSheet` returns, after this notification.
          Task { @MainActor in self?.focusField() }
        }
        focusField()
      }

      func stopWatching() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
      }

      /// Moves the keyboard to the editable text field of the sheet on this view's window.
      /// - Returns: Whether the field has the keyboard.
      @discardableResult
      func focusField() -> Bool {
        guard isPresented, let sheet = unsafe window?.attachedSheet,
          let field = Self.editableField(in: sheet.contentView)
        else { return false }
        if let editor = field.currentEditor(), sheet.firstResponder === editor { return true }
        return sheet.makeFirstResponder(field)
      }

      /// The first editable, enabled and shown text field under `view`, depth first.
      static func editableField(in view: NSView?) -> NSTextField? {
        guard let view, !view.isHidden else { return nil }
        if let field = view as? NSTextField, field.isEditable, field.isEnabled { return field }
        for subview in view.subviews {
          if let field = editableField(in: subview) { return field }
        }
        return nil
      }
    }
  }
#endif

extension View {
  /// On the Mac, the text field of an alert this view presents takes the keyboard when the
  /// alert opens, whatever AppKit's keyboard navigation would focus.
  /// - Parameter isPresented: Whether the alert is showing.
  /// - Returns: The view.
  func focusesAlertField(isPresented: Bool) -> some View {
    #if os(macOS)
      background { AlertFieldFocus(isPresented: isPresented) }
    #else
      self
    #endif
  }
}
