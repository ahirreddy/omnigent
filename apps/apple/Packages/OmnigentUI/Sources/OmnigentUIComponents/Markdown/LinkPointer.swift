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
    @State private var layouts = LinkTextLayouts()

    func body(content: Content) -> some View {
      if links.isEmpty {
        content
      } else {
        content.overlayPreferenceValue(Text.LayoutKey.self) { anchored in
          // A scroll moves the layout's anchor every frame. The layout is kept aside, so the
          // areas' view stays the same value: nothing measures or updates it.
          layouts.keep(anchored)
          return LinkPointerAreas(links: links, layouts: layouts)
        }
      }
    }
  }

  /// The latest layout of a linked `Text`. The modifier is on the `Text` itself, so the layout
  /// starts at the origin of the view over it.
  final class LinkTextLayouts {
    private(set) var layouts: [Text.Layout] = []
    /// Counts the layouts kept, so the areas find their rectangles again after a new one.
    private(set) var revision = 0

    func keep(_ anchored: [Text.LayoutKey.AnchoredLayout]) {
      layouts = anchored.map(\.layout)
      revision += 1
    }
  }

  /// Shows the pointing hand while the pointer is over a link of the selectable text under it.
  /// It takes no clicks, so the text still opens links, selects and shows its menus.
  struct LinkPointerAreas: NSViewRepresentable {
    let links: [LinkSpan]
    let layouts: LinkTextLayouts

    func makeNSView(context: Context) -> AreasView {
      let view = AreasView()
      view.show(links: links, layouts: layouts)
      return view
    }

    func updateNSView(_ view: AreasView, context: Context) {
      #if DEBUG
        RenderTally.count("link areas")
      #endif
      view.show(links: links, layouts: layouts)
    }

    final class AreasView: NSView {
      private var links: [LinkSpan] = []
      private var layouts: LinkTextLayouts?
      private var rects: [CGRect] = []
      /// The revision of the layouts ``rects`` were found in.
      private var rectsRevision: Int?
      private var area: NSTrackingArea?
      private lazy var turns = LinkHandTurns { [weak self] in self?.turnEnded() }
      /// Where the pointer is in the window; tests give their own, the real one is far away.
      var pointerLocation: (() -> NSPoint)?
      private var isOverLink = false {
        didSet { turns.isWatching = isOverLink }
      }

      override var isFlipped: Bool { true }

      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      func show(links: [LinkSpan], layouts: LinkTextLayouts) {
        self.links = links
        self.layouts = layouts
        rectsRevision = nil
      }

      /// Each link's rectangle on each line, found when the pointer first asks after a layout.
      var linkRects: [CGRect] {
        guard let layouts else { return [] }
        if rectsRevision == layouts.revision { return rects }
        rects = layouts.layouts.flatMap { LinkGeometry.rects(of: links, in: $0) }
        rectsRevision = layouts.revision
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

      private func turnEnded() {
        guard let location = unsafe turns.restingLocation(in: window, given: pointerLocation)
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

  /// The window's views set their cursors as it lays out and refreshes (SwiftUI's arrow, the
  /// text's I-beam). While the pointer rests on a link, the hand is put back as each turn of the
  /// main run loop ends, after all of them, and given up once the link is not under it.
  final class LinkHandTurns {
    private var observer: CFRunLoopObserver?
    private let turnEnded: @MainActor () -> Void

    init(_ turnEnded: @escaping @MainActor () -> Void) {
      self.turnEnded = turnEnded
    }

    /// Whether each turn's end is reported.
    var isWatching = false {
      didSet {
        guard isWatching != oldValue else { return }
        if isWatching { start() } else { stop() }
      }
    }

    private func start() {
      let turnEnded = turnEnded
      let observer = CFRunLoopObserverCreateWithHandler(
        nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
      ) { _, _ in
        MainActor.assumeIsolated { turnEnded() }
      }
      CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
      self.observer = observer
    }

    /// Reports a turn's end now, as the run loop does before it sleeps; for tests, whose loop
    /// never sleeps.
    func endTurn() {
      guard isWatching else { return }
      turnEnded()
    }

    private func stop() {
      if let observer { CFRunLoopObserverInvalidate(observer) }
      observer = nil
    }

    /// Where the pointer rests in `window` as a turn ends, or `nil` when the hand should be left
    /// alone: a selection drag keeps the text's I-beam, and a window behind another app's sets
    /// nothing. `location` stands in for the real pointer in tests.
    func restingLocation(in window: NSWindow?, given location: (() -> NSPoint)?) -> NSPoint? {
      guard NSEvent.pressedMouseButtons == 0, let window, window.isKeyWindow else { return nil }
      return location?() ?? window.mouseLocationOutsideOfEventStream
    }
  }
#endif
