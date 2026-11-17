#if os(macOS)
  import AppKit

  /// A message's selectable text on TextKit 2. Links show the pointing hand (``linkAt`` finds
  /// them), and copying gives plain text.
  final class MessageTextKitView: NSTextView {
    /// The link at a point in this view.
    var linkAt: ((CGPoint) -> URL?)?
    private var pointerArea: NSTrackingArea?
    /// Where the pointer is in the window; tests give their own, the real one is far away.
    var pointerLocation: (() -> NSPoint)?
    /// Puts the hand back as each turn ends while the pointer rests on a link.
    private(set) lazy var turns = LinkHandTurns { [weak self] in self?.turnEnded() }
    /// Whether the hand is up for a link under the pointer.
    private(set) var isOverLinkNow = false {
      didSet { turns.isWatching = isOverLinkNow }
    }

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

    /// The plain text a copy of `range` gives: without list markers, placeholder lines or
    /// attachment characters (``NSAttributedString/messageCopyText(in:)``).
    func copiedText(in range: NSRange) -> String {
      textContentStorage?.attributedString?.messageCopyText(in: range) ?? ""
    }

    /// The selection's copied text, its ranges a line apart.
    var copiedSelection: String {
      selectedRanges.map { copiedText(in: $0.rangeValue) }.joined(separator: "\n")
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType])
      -> Bool
    {
      let plain = types.filter { $0 == .string || $0.rawValue == "NSStringPboardType" }
      guard !plain.isEmpty, selectedRange().length > 0 else { return false }
      pboard.declareTypes(plain, owner: nil)
      let text = copiedSelection
      return plain.allSatisfy { pboard.setString(text, forType: $0) }
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
        rect: .zero,
        options: [
          .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect,
        ],
        owner: self)
      addTrackingArea(area)
      pointerArea = area
    }

    override func mouseMoved(with event: NSEvent) {
      super.mouseMoved(with: event)
      pointerMoved(to: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
      super.mouseExited(with: event)
      pointerMoved(to: event.locationInWindow)
    }

    override func cursorUpdate(with event: NSEvent) {
      if isOverLink(event.locationInWindow) {
        isOverLinkNow = true
        NSCursor.pointingHand.set()
      } else {
        super.cursorUpdate(with: event)
      }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      super.viewWillMove(toWindow: newWindow)
      if newWindow == nil, isOverLinkNow {
        isOverLinkNow = false
        NSCursor.arrow.set()
      }
    }

    /// The hand over a link this view shows, as ``LinkPointerAreas`` shows it over a `Text`:
    /// put back as each turn ends while the pointer rests there, then the I-beam over the text
    /// or the arrow off it.
    private func pointerMoved(to location: NSPoint) {
      if isOverLink(location) {
        isOverLinkNow = true
        if NSCursor.current != NSCursor.pointingHand { NSCursor.pointingHand.set() }
      } else if isOverLinkNow {
        isOverLinkNow = false
        (isOwnText(at: location) ? NSCursor.iBeam : NSCursor.arrow).set()
      }
    }

    private func turnEnded() {
      guard let location = unsafe turns.restingLocation(in: window, given: pointerLocation)
      else { return }
      pointerMoved(to: location)
    }

    /// Whether a link is under `location`, in the window's coordinates, and nothing covers it.
    func isOverLink(_ location: NSPoint) -> Bool {
      linkAt?(convert(location, from: nil)) != nil && isOwnText(at: location)
    }

    /// Whether a click at `location`, in the window's coordinates, would reach this text.
    private func isOwnText(at location: NSPoint) -> Bool {
      // AppKit declares `window` and `superview` unowned(unsafe); both are only read here.
      guard let content = unsafe window?.contentView else { return false }
      let hit = unsafe content.hitTest(content.superview?.convert(location, from: nil) ?? location)
      return hit.map { $0 === self || $0.isDescendant(of: self) } ?? false
    }

    /// Sets the view up to show message text: read-only and selectable, transparent, with no
    /// insets, links in `palette`'s color, and find left to the window.
    func configureForMessage(palette: MessageTextPalette) {
      isEditable = false
      isSelectable = true
      isRichText = true
      importsGraphics = false
      drawsBackground = false
      textContainerInset = .zero
      isVerticallyResizable = false
      isHorizontallyResizable = false
      // Find stays the window's: one message's own find bar or panel would search only it.
      usesFindBar = false
      usesFindPanel = false
      isIncrementalSearchingEnabled = false
      displaysLinkToolTips = false
      isAutomaticLinkDetectionEnabled = false
      linkTextAttributes = [
        .foregroundColor: palette.link,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
        .cursor: NSCursor.pointingHand,
      ]
    }
  }
#endif
