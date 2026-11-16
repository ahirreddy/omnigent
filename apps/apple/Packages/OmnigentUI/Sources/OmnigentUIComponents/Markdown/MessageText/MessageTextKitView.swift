#if os(macOS)
  import AppKit

  /// A message's selectable text on TextKit 2. Links show the pointing hand (``linkAt`` finds
  /// them), and copying gives plain text.
  final class MessageTextKitView: NSTextView {
    /// The link at a point in this view.
    var linkAt: ((CGPoint) -> URL?)?
    private var pointerArea: NSTrackingArea?

    /// `omnigent:message-text-viewport full`: TextKit's viewport covers the whole text, so its
    /// fragments draw once instead of being recycled and drawn again as the transcript scrolls.
    static let viewportCoversText =
      UserDefaults.standard.string(forKey: "omnigent:message-text-viewport") == "full"

    override var visibleRect: NSRect {
      Self.viewportCoversText ? bounds : super.visibleRect
    }

    override var preparedContentRect: NSRect {
      get { Self.viewportCoversText ? bounds : super.preparedContentRect }
      set { super.preparedContentRect = newValue }
    }

    /// Copies as plain text, as a selection on the web does: of the types the text view writes,
    /// only its plain string (under its modern name or its legacy one).
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
      super.writablePasteboardTypes.filter {
        $0 == .string || $0.rawValue == "NSStringPboardType"
      }
    }

    override func resignFirstResponder() -> Bool {
      let resigned = super.resignFirstResponder()
      // One selection in the transcript at a time: a click elsewhere ends this one.
      let selected = selectedRange()
      if resigned, selected.length > 0 {
        setSelectedRange(NSRange(location: selected.location, length: 0))
      }
      return resigned
    }

    /// With nothing selected, a right click opens the message's own menu, as beside the text.
    override func menu(for event: NSEvent) -> NSMenu? {
      selectedRange().length > 0 ? super.menu(for: event) : nil
    }

    override func rightMouseDown(with event: NSEvent) {
      guard selectedRange().length > 0 else {
        // AppKit declares `nextResponder` unowned(unsafe); it is only messaged here.
        unsafe nextResponder?.rightMouseDown(with: event)
        return
      }
      super.rightMouseDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
      // A click selects here, so this view takes the keyboard first, as a text field does.
      if let window = unsafe window, window.firstResponder !== self {
        window.makeFirstResponder(self)
      }
      super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      // One area that follows the visible rect, so scrolling rebuilds nothing.
      guard pointerArea == nil else { return }
      let area = NSTrackingArea(
        rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
        owner: self)
      addTrackingArea(area)
      pointerArea = area
    }

    override func mouseMoved(with event: NSEvent) {
      super.mouseMoved(with: event)
      if isOverLink(event.locationInWindow) { NSCursor.pointingHand.set() }
    }

    override func cursorUpdate(with event: NSEvent) {
      if isOverLink(event.locationInWindow) {
        NSCursor.pointingHand.set()
      } else {
        super.cursorUpdate(with: event)
      }
    }

    /// Whether a link is under `location`, in the window's coordinates.
    func isOverLink(_ location: NSPoint) -> Bool {
      linkAt?(convert(location, from: nil)) != nil
    }
  }
#endif
