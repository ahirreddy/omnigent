#if os(macOS)
  import AppKit
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

    override func scrollWheel(with event: NSEvent) {
      owner?.readerScrolled()
      super.scrollWheel(with: event)
    }

    /// The transcript fills what SwiftUI gives it; its size never follows its content. AppKit
    /// invalidates it as the rows' height or the scrollers change, which would have SwiftUI lay
    /// the whole window out again on a scroll's every step.
    override func invalidateIntrinsicContentSize() {}

    override func viewWillStartLiveResize() {
      super.viewWillStartLiveResize()
      owner?.liveResizeChanged(true)
    }

    override func viewDidEndLiveResize() {
      super.viewDidEndLiveResize()
      owner?.liveResizeChanged(false)
    }
  }

  /// The table: one column, no selection, and cells whose text takes the first click.
  final class TranscriptTableNSView: NSTableView {
    /// Selectable text and controls in a row take a click at once, not only once a row is
    /// selected, as a table's editable cells otherwise do.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?)
      -> Bool
    {
      true
    }
  }
#endif
