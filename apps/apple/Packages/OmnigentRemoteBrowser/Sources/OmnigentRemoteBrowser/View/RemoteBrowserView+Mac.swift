#if os(macOS)
  public import AppKit
  import OmnigentCoreFFI
  public import OmnigentInput

  /// macOS input: the shared `InputTranslator` for mouse, trackpad and keys, the shared
  /// `TextInputComposer` for IME, mapped to the remote viewport by `RemoteInputMapping`.
  extension RemoteBrowserView {
    override public var acceptsFirstResponder: Bool { true }

    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override public func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let trackingArea { removeTrackingArea(trackingArea) }
      let area = NSTrackingArea(
        rect: .zero,
        options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self)
      addTrackingArea(area)
      trackingArea = area
    }

    // MARK: Mouse

    private func forwardMouse(_ event: NSEvent) {
      let location = convert(event.locationInWindow, from: nil)
      guard let geometry,
        let pointer = InputTranslator.pointerInput(for: event, location: location)
      else { return }
      guard let input = RemoteInputMapping.mouse(pointer, geometry: geometry) else {
        // Over the letterbox: the page sees the pointer leave once.
        if pointerInside, pointer.kind == .move {
          pointerInside = false
          var leave = pointer
          leave.kind = .leave
          RemoteInputMapping.mouse(leave, geometry: geometry).map(store.send)
        }
        return
      }
      pointerInside = input.kind != .leave
      store.send(input)
    }

    override public func mouseDown(with event: NSEvent) {
      hostWindow?.makeFirstResponder(self)
      forwardMouse(event)
    }

    override public func rightMouseDown(with event: NSEvent) {
      hostWindow?.makeFirstResponder(self)
      forwardMouse(event)
    }

    override public func mouseUp(with event: NSEvent) { forwardMouse(event) }
    override public func mouseDragged(with event: NSEvent) { forwardMouse(event) }
    override public func mouseMoved(with event: NSEvent) { forwardMouse(event) }
    override public func mouseEntered(with event: NSEvent) { forwardMouse(event) }
    override public func mouseExited(with event: NSEvent) { forwardMouse(event) }
    override public func rightMouseUp(with event: NSEvent) { forwardMouse(event) }
    override public func rightMouseDragged(with event: NSEvent) { forwardMouse(event) }
    override public func otherMouseDown(with event: NSEvent) { forwardMouse(event) }
    override public func otherMouseUp(with event: NSEvent) { forwardMouse(event) }
    override public func otherMouseDragged(with event: NSEvent) { forwardMouse(event) }
    override public func scrollWheel(with event: NSEvent) { forwardMouse(event) }

    // MARK: Keyboard

    override public func keyDown(with event: NSEvent) {
      guard !event.modifierFlags.contains(.command) else {
        forwardKeyEvent(event)
        return
      }
      textComposer.keyDown(event, context: inputContext)
    }

    override public func keyUp(with event: NSEvent) {
      sendKeys(event)
    }

    override public func flagsChanged(with event: NSEvent) {
      sendKeys(event)
    }

    /// Editing chords go to the page while it has focus; other shortcuts stay with the app,
    /// since the remote page cannot hand back keys it did not handle.
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
      guard event.type == .keyDown, hostWindow?.firstResponder === self, store.canSendInput,
        event.modifierFlags.intersection([.command, .control, .option]) == .command,
        let key = event.charactersIgnoringModifiers?.lowercased(),
        Self.pageEditingKeys.contains(key)
      else { return super.performKeyEquivalent(with: event) }
      forwardKeyEvent(event)
      return true
    }

    private static let pageEditingKeys: Set<String> = ["a", "c", "v", "x", "z"]

    private func sendKeys(_ event: NSEvent) {
      let inputs = InputTranslator.keyInputs(for: event)
      let characters = event.type == .flagsChanged ? "" : (event.characters ?? "")
      for key in RemoteInputMapping.keys(inputs, characters: characters) {
        store.send(key)
      }
    }

    // MARK: Cursor

    override public func resetCursorRects() {
      guard let geometry else { return }
      addCursorRect(geometry.contentRect, cursor: currentCursor)
    }

    func cursorChanged() {
      guard let window = hostWindow else { return }
      window.invalidateCursorRects(for: self)
      let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
      if geometry?.contentRect.contains(point) == true { currentCursor.set() }
    }

    private var currentCursor: NSCursor {
      if let custom = store.snapshot.cursor.custom, let image = NSImage(data: custom.png) {
        let factor = (geometry?.scale ?? 1) / max(custom.scale, 1)
        image.size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
        return NSCursor(
          image: image,
          hotSpot: NSPoint(x: custom.hotspotX * factor, y: custom.hotspotY * factor))
      }
      return store.snapshot.cursor.pageCursor.nsCursor
    }

    /// `NSView.window` is `unowned(unsafe)`; AppKit keeps it valid while the view is in a
    /// window, and this view only reads it on the main thread during its own callbacks.
    var hostWindow: NSWindow? { unsafe window }
  }

  // MARK: IME

  extension RemoteBrowserView: TextInputSink {
    /// Sends a plain key.
    public func forwardKeyEvent(_ event: NSEvent) {
      sendKeys(event)
    }

    /// Sends committed text.
    public func commitText(_ text: String, replacementRange: NSRange) {
      store.send(
        ImeInput(
          op: .commit, text: text, selection: nil, replacement: ImeRange(replacementRange)))
    }

    /// Sends marked text.
    public func setComposition(_ text: String, selectedRange: NSRange, replacementRange: NSRange)
    {
      store.send(
        ImeInput(
          op: .setComposition, text: text, selection: ImeRange(selectedRange),
          replacement: ImeRange(replacementRange)))
    }

    /// Commits the composition.
    public func finishComposing(keepSelection: Bool) {
      store.send(ImeInput(op: .finish, text: nil, selection: nil, replacement: nil))
    }

    /// Drops the composition.
    public func cancelComposition() {
      store.send(ImeInput(op: .cancel, text: nil, selection: nil, replacement: nil))
    }
  }

  extension RemoteBrowserView: NSTextInputClient {
    /// `NSTextInputClient`: inserted text.
    public func insertText(_ string: Any, replacementRange: NSRange) {
      textComposer.insertText(string, replacementRange: replacementRange)
    }

    /// `NSTextInputClient`: marked text.
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
      textComposer.setMarkedText(
        string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    /// `NSTextInputClient`: commit marked text.
    public func unmarkText() {
      textComposer.unmarkText()
    }

    /// `NSTextInputClient`: whether text is marked.
    public func hasMarkedText() -> Bool {
      textComposer.hasMarkedText
    }

    /// `NSTextInputClient`: the marked range.
    public func markedRange() -> NSRange {
      textComposer.markedRange
    }

    /// `NSTextInputClient`: no selection is mirrored from the page.
    public func selectedRange() -> NSRange {
      NSRange(location: NSNotFound, length: 0)
    }

    /// `NSTextInputClient`: underline and background.
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
      TextInputComposer.validAttributesForMarkedText
    }

    /// `NSTextInputClient`: page text is not mirrored.
    public func attributedSubstring(
      forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? {
      // The remote page's text is not mirrored here.
      nil
    }

    /// `NSTextInputClient`: not available for a remote page.
    public func characterIndex(for point: NSPoint) -> Int {
      NSNotFound
    }

    /// The candidate window sits at the page's bottom-left until the host reports caret rects.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?)
      -> NSRect
    {
      guard let window = hostWindow else { return .zero }
      let rect = geometry?.contentRect ?? bounds
      let local = CGRect(x: rect.minX, y: rect.maxY, width: 0, height: 0)
      return window.convertToScreen(convert(local, to: nil))
    }

    override public func doCommand(by selector: Selector) {
      // Editing commands reach the page as the key events `keyDown` forwards.
    }
  }
#endif
