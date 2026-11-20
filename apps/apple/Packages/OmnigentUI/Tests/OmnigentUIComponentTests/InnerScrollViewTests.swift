#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// ``ScrollGestureRouter`` between an inner scroll view and the one around it: which takes each
  /// gesture, and that the rest of the gesture follows it.
  @Suite("Inner scroll views", .serialized)
  @MainActor
  struct InnerScrollViewTests {
    /// The scroll view around the inner one, keeping the phases of what reaches it.
    private final class OuterScroller: NSView, RoutedScroller {
      var taken: [NSEvent.Phase] = []
      var isOutermost: Bool { true }
      func accepts(_ event: NSEvent) -> Bool { true }
      func scroll(for event: NSEvent) { taken.append(event.phase) }
      override func scrollWheel(with event: NSEvent) {
        ScrollGestureRouter.deliver(event, to: self)
      }
    }

    /// An inner scroll view keeping the phases it scrolls for.
    private final class RecordingInnerScrollView: InnerScrollView {
      var taken: [NSEvent.Phase] = []
      override func scroll(for event: NSEvent) {
        taken.append(event.phase)
        super.scroll(for: event)
      }
    }

    private final class FlippedView: NSView {
      override var isFlipped: Bool { true }
    }

    /// An inner scroll view 200 by 100 over `content`, in an outer one, in a window.
    private struct Nest {
      let window: NSWindow
      let outer = OuterScroller(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
      let inner = RecordingInnerScrollView(frame: CGRect(x: 0, y: 100, width: 200, height: 100))

      init(content: CGSize) {
        inner.hasVerticalScroller = content.height > 100
        inner.hasHorizontalScroller = content.width > 200
        inner.documentView = FlippedView(frame: CGRect(origin: .zero, size: content))
        outer.addSubview(inner)
        window = NSWindow(
          contentRect: CGRect(x: -20_000, y: -20_000, width: 200, height: 300),
          styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = outer
      }

      func close() { window.contentView = nil }

      /// Sends the inner view a scroll `across` and `down` points.
      func send(
        _ phase: CGScrollPhase?, momentum: CGMomentumScrollPhase = .none, across: Int32 = 0,
        down: Int32 = 0
      ) throws {
        let event = try #require(
          CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: down,
            wheel2: across, wheel3: 0))
        event.setIntegerValueField(
          .scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        event.setIntegerValueField(
          .scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        inner.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
      }
    }

    @Test("A vertical inner scroller at its edge hands a scroll that way out, and takes the other")
    func verticalEdge() throws {
      let nest = Nest(content: CGSize(width: 200, height: 500))
      defer { nest.close() }
      // At the top, a wheel step up goes out; one down scrolls the inner view.
      try nest.send(nil, down: 20)
      #expect(nest.outer.taken.count == 1)
      try nest.send(nil, down: -20)
      #expect(nest.outer.taken.count == 1)
      #expect(nest.inner.taken.count == 1)
      // At the top again, a gesture up goes out, all of it.
      nest.inner.contentView.scroll(to: .zero)
      nest.outer.taken = []
      nest.inner.taken = []
      try nest.send(.began, down: 20)
      try nest.send(.changed, down: 20)
      try nest.send(.changed, down: -20)
      try nest.send(.ended)
      #expect(nest.outer.taken == [.began, .changed, .changed, .ended])
      #expect(nest.inner.taken.isEmpty)
      // A gesture down stays with the inner view, all of it.
      nest.outer.taken = []
      try nest.send(.began, down: -20)
      try nest.send(.changed, down: -20)
      try nest.send(.changed, down: 20)
      try nest.send(.ended)
      #expect(nest.outer.taken.isEmpty)
      #expect(nest.inner.taken == [.began, .changed, .changed, .ended])
    }

    @Test("A sideways inner scroller takes a sideways gesture and its momentum, and no other")
    func sideways() throws {
      let nest = Nest(content: CGSize(width: 600, height: 100))
      defer { nest.close() }
      try nest.send(.began, across: -20)
      try nest.send(.changed, across: -20, down: 30)
      try nest.send(.ended)
      try nest.send(nil, momentum: .begin, across: -10)
      try nest.send(nil, momentum: .continuous, down: 10)
      try nest.send(nil, momentum: .end)
      #expect(nest.inner.taken.count == 6)
      #expect(nest.outer.taken.isEmpty)
      // Up and down, the gesture and its momentum go out, though the inner view is under them.
      nest.inner.taken = []
      try nest.send(.began, down: 20)
      try nest.send(.changed, across: -30)
      try nest.send(.ended)
      try nest.send(nil, momentum: .begin, down: 10)
      try nest.send(nil, momentum: .end)
      #expect(nest.inner.taken.isEmpty)
      #expect(nest.outer.taken.count == 5)
    }

    @Test("A gesture that began elsewhere, momentum too, goes out over an inner scroller")
    func beganElsewhere() throws {
      let nest = Nest(content: CGSize(width: 600, height: 100))
      defer { nest.close() }
      // The outer view sees the gesture begin, then the inner one comes under the pointer.
      try nest.send(.began, across: -20)
      try nest.send(.ended)
      nest.inner.taken = []
      nest.outer.scrollWheel(with: try Self.event(.began, down: 20))
      try nest.send(.changed, across: -30)
      try nest.send(.ended)
      try nest.send(nil, momentum: .begin, across: -10)
      try nest.send(nil, momentum: .end)
      #expect(nest.inner.taken.isEmpty)
      #expect(nest.outer.taken.count == 5)
    }

    @Test("A gesture that begins without moving goes where its first move points, from its start")
    func beginsStill() throws {
      let nest = Nest(content: CGSize(width: 600, height: 100))
      defer { nest.close() }
      try nest.send(.began)
      #expect(nest.inner.taken.isEmpty && nest.outer.taken.isEmpty)
      try nest.send(.changed, across: -20)
      try nest.send(.ended)
      #expect(nest.inner.taken == [.began, .changed, .ended])
      nest.inner.taken = []
      try nest.send(.began)
      try nest.send(.changed, down: 20)
      try nest.send(.ended)
      #expect(nest.inner.taken.isEmpty)
      #expect(nest.outer.taken == [.began, .changed, .ended])
    }

    @Test("SwiftUI content that fits shows plainly; wider content scrolls in an inner scroll view")
    func sidewaysContent() throws {
      SystemSideEffects.reset()
      func screen(width: CGFloat) -> OffscreenWindow<some View> {
        OffscreenWindow(
          SidewaysScrollView { Color.red.frame(width: width, height: 40) }
            .frame(maxHeight: .infinity, alignment: .top),
          width: 300, height: 200)
      }
      let narrow = screen(width: 100)
      defer { narrow.close() }
      #expect(!narrow.allViews.contains { $0 is NSScrollView })
      let wide = screen(width: 600)
      defer { wide.close() }
      let scroll = try #require(wide.allViews.compactMap { $0 as? InnerScrollView }.first)
      let scroller =
        scroll.scrollerStyle == .legacy
        ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
      #expect(scroll.frame.size == CGSize(width: 300, height: 40 + scroller))
      #expect(scroll.documentView?.frame.width == 600)
    }

    private static func event(_ phase: CGScrollPhase, down: Int32) throws -> NSEvent {
      let event = try #require(
        CGEvent(
          scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: down, wheel2: 0,
          wheel3: 0))
      event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
      return try #require(NSEvent(cgEvent: event))
    }
  }
#endif
