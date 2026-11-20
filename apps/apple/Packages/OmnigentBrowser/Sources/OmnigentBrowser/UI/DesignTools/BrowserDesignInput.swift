#if os(macOS)
  internal import AppKit
  internal import SwiftUI

  /// What the tools' input layer reports, in its points from the top left.
  struct BrowserDesignInputHandlers {
    var move: (CGPoint) -> Void = { _ in }
    var press: (CGPoint) -> Void = { _ in }
    var drag: (CGPoint) -> Void = { _ in }
    var release: (CGPoint) -> Void = { _ in }
    var escape: () -> Void = {}
  }

  /// A transparent layer over the page that takes the pointer and the keys while a tool is
  /// open, so the page sees none of them. The wheel still scrolls the page when `scrolls`.
  struct BrowserDesignInput: NSViewRepresentable {
    let handlers: BrowserDesignInputHandlers
    let cursor: NSCursor
    let scrolls: Bool
    /// The page's view, which the wheel scrolls and the keys go back to.
    let page: NSView?
    /// The view that takes typing for the page.
    let pageKeyboard: NSView?

    func makeNSView(context: Context) -> BrowserDesignInputView {
      let view = BrowserDesignInputView()
      update(view)
      return view
    }

    func updateNSView(_ view: BrowserDesignInputView, context: Context) {
      update(view)
    }

    static func dismantleNSView(_ view: BrowserDesignInputView, coordinator: ()) {
      view.handBackKeys()
    }

    private func update(_ view: BrowserDesignInputView) {
      view.handlers = handlers
      view.scrollTarget = scrolls ? page : nil
      view.pageKeyboard = pageKeyboard
      if view.cursor != cursor {
        view.cursor = cursor
        view.window?.invalidateCursorRects(for: view)
      }
    }
  }

  /// The input layer's view: tracks the pointer, swallows the page's keys and context menu.
  final class BrowserDesignInputView: NSView {
    var handlers = BrowserDesignInputHandlers()
    var cursor = NSCursor.crosshair
    weak var scrollTarget: NSView?
    weak var pageKeyboard: NSView?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      // The tool takes the keys from the page as it opens.
      window?.makeFirstResponder(self)
    }

    /// Gives the keys back to the page if the layer held them as it goes.
    func handBackKeys() {
      guard let window, window.firstResponder === self else { return }
      window.makeFirstResponder(pageKeyboard)
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(
        rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
        owner: self)
      addTrackingArea(area)
      tracking = area
    }

    override func resetCursorRects() {
      addCursorRect(bounds, cursor: cursor)
    }

    override func cursorUpdate(with event: NSEvent) {
      cursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
      handlers.move(point(of: event))
    }

    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      handlers.press(point(of: event))
    }

    override func mouseDragged(with event: NSEvent) {
      handlers.drag(point(of: event))
    }

    override func mouseUp(with event: NSEvent) {
      handlers.release(point(of: event))
    }

    override func rightMouseDown(with event: NSEvent) {}

    override func otherMouseDown(with event: NSEvent) {}

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func scrollWheel(with event: NSEvent) {
      guard let scrollTarget else { return }
      scrollTarget.scrollWheel(with: event)
      handlers.move(point(of: event))
    }

    override func keyDown(with event: NSEvent) {
      // Escape leaves the tool; other keys stop here rather than reach the page.
      if event.keyCode == Self.escapeKeyCode { handlers.escape() }
    }

    override func cancelOperation(_ sender: Any?) {
      handlers.escape()
    }

    private static let escapeKeyCode: UInt16 = 53

    private func point(of event: NSEvent) -> CGPoint {
      convert(event.locationInWindow, from: nil)
    }
  }
#endif
