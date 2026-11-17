#if os(macOS)
  import AppKit
  import QuartzCore
  import SwiftUI

  /// The table transcript's clip view: AppKit asks it to constrain every bounds change, scrolls
  /// included, so the controller measures the rows a scroll is about to show before they show,
  /// and moves the origin with the reader's row when rows above it change height.
  final class TranscriptTableClipView: NSClipView {
    weak var owner: TranscriptTableController?

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
      let constrained = super.constrainBoundsRect(proposedBounds)
      guard let owner else { return constrained }
      let origin = owner.clipWillMove(to: constrained.origin)
      guard origin != constrained.origin else { return constrained }
      return super.constrainBoundsRect(NSRect(origin: origin, size: constrained.size))
    }

    override func setFrameSize(_ newSize: NSSize) {
      owner?.viewportWillResize(to: newSize)
      super.setFrameSize(newSize)
      owner?.viewportResized()
    }
  }

  /// The table transcript's scroll view: it tells the controller about wheel and trackpad
  /// events, which are the reader's scrolls, before it scrolls for them. Overriding
  /// `scrollWheel` keeps it out of responsive scrolling, as SwiftUI's scroll view is: that
  /// scrolls a gesture on its own thread from the window's event queue.
  final class TranscriptTableScrollView: NSScrollView {
    weak var owner: TranscriptTableController?
    /// The soft edges under the bars: rows fade out as they pass under them, as SwiftUI's soft
    /// scroll edge effect fades the stack's.
    let edgeMask = CAGradientLayer()

    override func scrollWheel(with event: NSEvent) {
      owner?.readerScrolled()
      super.scrollWheel(with: event)
    }

    /// The transcript fills what SwiftUI gives it; its size never follows its content. AppKit
    /// invalidates it as the rows' height or the scrollers change, which would have SwiftUI lay
    /// the whole window out again on a scroll's every step.
    override func invalidateIntrinsicContentSize() {}

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      // A scroll under way paused this window's cursor rects: they come back as it goes.
      if unsafe newWindow !== window { owner?.resumeCursorRects() }
      super.viewWillMove(toWindow: newWindow)
    }

    override func viewWillStartLiveResize() {
      super.viewWillStartLiveResize()
      owner?.liveResizeChanged(true)
    }

    override func viewDidEndLiveResize() {
      super.viewDidEndLiveResize()
      owner?.liveResizeChanged(false)
    }

    override func tile() {
      super.tile()
      updateEdgeMask()
    }

    /// Fades the rows across the bars' insets, opaque between them.
    func updateEdgeMask() {
      let height = bounds.height
      let top = min(max(0, contentInsets.top), height / 2)
      let bottom = min(max(0, contentInsets.bottom), height / 2)
      guard height > 0, top > 0 || bottom > 0 else {
        layer?.mask = nil
        return
      }
      wantsLayer = true
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      defer { CATransaction.commit() }
      edgeMask.frame = bounds
      let clear = CGColor(gray: 0, alpha: 0)
      let opaque = CGColor(gray: 0, alpha: 1)
      edgeMask.colors = [clear, opaque, opaque, clear]
      // A layer's unit space starts at the bottom of a view that is not flipped.
      let (first, last) = isFlipped ? (top, bottom) : (bottom, top)
      edgeMask.locations = [0, first / height, 1 - last / height, 1].map {
        // swiftlint:disable:next legacy_objc_type
        NSNumber(value: Double($0))
      }
      edgeMask.startPoint = CGPoint(x: 0.5, y: 0)
      edgeMask.endPoint = CGPoint(x: 0.5, y: 1)
      if layer?.mask !== edgeMask { layer?.mask = edgeMask }
    }
  }

  /// The table: one column, no selection, and cells whose text takes the first click.
  final class TranscriptTableNSView: NSTableView, MessageTextKeyScrolling {
    weak var owner: TranscriptTableController?
    /// The table takes the keyboard only to keep it when the row view that has it leaves, so
    /// the keys go on scrolling; a click goes to the rows' text and controls.
    private var holdsKeyboard = false

    /// Selectable text and controls in a row take a click at once, not only once a row is
    /// selected, as a table's editable cells otherwise do.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?)
      -> Bool
    {
      true
    }

    override var acceptsFirstResponder: Bool { holdsKeyboard }

    override func resignFirstResponder() -> Bool {
      let resigned = super.resignFirstResponder()
      if resigned { holdsKeyboard = false }
      return resigned
    }

    /// Keys a focused row or a message's text passes on scroll the transcript.
    override func keyDown(with event: NSEvent) {
      if owner?.scrolls(for: event) == true { return }
      super.keyDown(with: event)
    }

    func scrollsForKey(_ event: NSEvent) -> Bool { owner?.scrolls(for: event) == true }

    /// A row view leaving with the keyboard in it, as a scroll by keys takes it out of view,
    /// hands the keyboard to the table, which goes on scrolling for the keys.
    override func willRemoveSubview(_ subview: NSView) {
      super.willRemoveSubview(subview)
      // AppKit declares `window` unowned(unsafe); it is only read here.
      guard let window = unsafe window, let responder = window.firstResponder as? NSView,
        responder !== self, responder.isDescendant(of: subview)
      else { return }
      holdsKeyboard = true
      if !window.makeFirstResponder(self) { holdsKeyboard = false }
    }

    // An assistive client reads the rows in order, as it reads the stack's: a group of the rows'
    // own elements, not a table of selectable rows.
    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    // swiftlint:disable:next discouraged_optional_collection
    override func accessibilityChildren() -> [Any]? {
      owner?.accessibilityRows() ?? super.accessibilityChildren()
    }
  }
#endif
