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
  final class TranscriptTableNSView: NSTableView {
    weak var owner: TranscriptTableController?

    /// Selectable text and controls in a row take a click at once, not only once a row is
    /// selected, as a table's editable cells otherwise do.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?)
      -> Bool
    {
      true
    }

    /// Keys a focused row passes on scroll the transcript, as a text view's do.
    override func keyDown(with event: NSEvent) {
      if owner?.scrolls(for: event) == true { return }
      super.keyDown(with: event)
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
