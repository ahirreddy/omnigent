import SwiftUI

extension View {
  /// On the Mac the pointer becomes a hand over the links of the selectable `Text` this is
  /// applied to. `links` says where they are (``LinkGeometry/spans(in:)``); a text with none
  /// gets nothing added, and no other platform reads them.
  func linkPointer(_ links: @autoclosure () -> [LinkSpan]) -> some View {
    #if os(macOS)
      modifier(LinkPointer(links: links()))
    #else
      self
    #endif
  }
}

#if os(macOS)
  import AppKit

  /// Hands a linked text's layout to ``LinkPointerAreas``, which reads it once the pointer is
  /// over the text.
  private struct LinkPointer: ViewModifier {
    let links: [LinkSpan]

    func body(content: Content) -> some View {
      if links.isEmpty {
        content
      } else {
        content.overlayPreferenceValue(Text.LayoutKey.self) { layouts in
          GeometryReader { proxy in
            LinkPointerAreas(
              links: links,
              layouts: layouts.map { PlacedTextLayout(origin: proxy[$0.origin], layout: $0.layout) }
            )
          }
        }
      }
    }
  }

  /// A text's layout and where it starts in the view over it.
  struct PlacedTextLayout {
    let origin: CGPoint
    let layout: Text.Layout
  }

  /// Shows the pointing hand while the pointer is over a link of the selectable text under it.
  /// It takes no clicks, so the text still opens links, selects and shows its menus.
  struct LinkPointerAreas: NSViewRepresentable {
    let links: [LinkSpan]
    let layouts: [PlacedTextLayout]

    func makeNSView(context: Context) -> AreasView {
      let view = AreasView()
      view.show(links: links, layouts: layouts)
      return view
    }

    func updateNSView(_ view: AreasView, context: Context) {
      view.show(links: links, layouts: layouts)
    }

    final class AreasView: NSView {
      private var links: [LinkSpan] = []
      private var layouts: [PlacedTextLayout] = []
      private var rects: [CGRect] = []
      private var rectsAreFound = false
      private var area: NSTrackingArea?
      private var turnObserver: CFRunLoopObserver?
      /// Where the pointer is in the window; tests give their own, the real one is far away.
      var pointerLocation: (() -> NSPoint)?
      private var isOverLink = false {
        didSet {
          guard isOverLink != oldValue else { return }
          if isOverLink { watchTurns() } else { stopWatchingTurns() }
        }
      }

      override var isFlipped: Bool { true }

      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      func show(links: [LinkSpan], layouts: [PlacedTextLayout]) {
        self.links = links
        self.layouts = layouts
        rectsAreFound = false
      }

      /// Each link's rectangle on each line, found when the pointer first asks after a layout.
      var linkRects: [CGRect] {
        if rectsAreFound { return rects }
        rects = layouts.flatMap { placed in
          LinkGeometry.rects(of: links, in: placed.layout)
            .map { $0.offsetBy(dx: placed.origin.x, dy: placed.origin.y) }
        }
        rectsAreFound = true
        return rects
      }

      override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // One area that follows the visible rect by itself, so scrolling rebuilds nothing.
        guard area == nil else { return }
        let area = NSTrackingArea(
          rect: .zero,
          options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
          owner: self)
        addTrackingArea(area)
        self.area = area
      }

      override func mouseEntered(with event: NSEvent) { pointerMoved(to: event.locationInWindow) }
      override func mouseMoved(with event: NSEvent) { pointerMoved(to: event.locationInWindow) }
      override func mouseExited(with event: NSEvent) { pointerMoved(to: event.locationInWindow) }

      override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, isOverLink { leaveLink(at: nil) }
      }

      private func pointerMoved(to location: NSPoint) {
        let point = convert(location, from: nil)
        guard linkRects.contains(where: { $0.contains(point) }), isOwnText(at: location) else {
          if isOverLink { leaveLink(at: location) }
          return
        }
        isOverLink = true
        if NSCursor.current != NSCursor.pointingHand { NSCursor.pointingHand.set() }
      }

      /// The window's views set their cursors as it lays out and refreshes (SwiftUI's arrow, the
      /// text's I-beam). While the pointer rests on a link, the hand is put back as each turn of
      /// the main run loop ends, after all of them, and given up once the link is not under it.
      private func watchTurns() {
        let observer = CFRunLoopObserverCreateWithHandler(
          nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { [weak self] _, _ in
          MainActor.assumeIsolated { self?.turnEnded() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        turnObserver = observer
      }

      private func stopWatchingTurns() {
        if let turnObserver { CFRunLoopObserverInvalidate(turnObserver) }
        turnObserver = nil
      }

      private func turnEnded() {
        // A selection drag keeps the text's I-beam; a window behind another app's sets nothing.
        // AppKit declares `window` unowned(unsafe); it is only read here, never retained.
        guard NSEvent.pressedMouseButtons == 0, unsafe window?.isKeyWindow == true,
          let location = unsafe pointerLocation?() ?? window?.mouseLocationOutsideOfEventStream
        else { return }
        pointerMoved(to: location)
      }

      /// Puts back the cursor of what the pointer is over now: the I-beam over selectable text.
      private func leaveLink(at location: NSPoint?) {
        isOverLink = false
        let isOverText = location.map { Self.isSelectableText(viewUnder($0)) } ?? false
        (isOverText ? NSCursor.iBeam : NSCursor.arrow).set()
      }

      /// This text is what a click at `location` would reach: nothing covers it there, and it
      /// is not a tab kept behind the shown one.
      private func isOwnText(at location: NSPoint) -> Bool {
        guard let under = viewUnder(location), Self.isSelectableText(under) else { return false }
        // The text's selection view is about its size: most of either is in the other.
        let own = convert(bounds, to: nil)
        let other = under.convert(under.bounds, to: nil)
        let shared = own.intersection(other)
        return shared.width * shared.height * 2
          > max(own.width * own.height, other.width * other.height)
      }

      private func viewUnder(_ location: NSPoint) -> NSView? {
        // AppKit declares `window` and `superview` unowned(unsafe); both are only read here.
        guard let content = unsafe window?.contentView else { return nil }
        return unsafe content.hitTest(content.superview?.convert(location, from: nil) ?? location)
      }

      /// SwiftUI's selectable `Text` is an `NSTextField`, and its field editor once clicked.
      private static func isSelectableText(_ view: NSView?) -> Bool {
        view is NSText || (view as? NSTextField)?.isSelectable == true
      }
    }
  }
#endif
