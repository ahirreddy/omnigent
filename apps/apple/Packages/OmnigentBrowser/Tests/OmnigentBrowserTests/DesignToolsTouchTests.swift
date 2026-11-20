#if os(iOS)
  import CoreGraphics
  import Testing
  import UIKit

  @testable import OmnigentBrowser

  /// Annotate and Draw on iPhone and iPad: what the touch layer reports for taps, one finger or
  /// Apple Pencil, two fingers, Pencil's double tap and a keyboard's Escape.
  @MainActor
  @Suite("Design tools on iPhone and iPad: the touch layer")
  struct DesignToolsTouchTests {
    /// A layer 200 by 100 points recording what it reports, by name and point.
    private func layer(_ events: EventLog) -> BrowserDesignTouchView {
      let view = BrowserDesignTouchView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
      let name = { (word: String) in { (point: CGPoint) in events.add("\(word) \(point)") } }
      view.handlers = BrowserDesignInputHandlers(
        move: name("move"), press: name("down"), drag: name("drag"), release: name("up"),
        escape: { events.add("escape") }, scrolled: { events.add("scrolled") },
        undo: { events.add("undo") }, previousTool: { events.add("previous") })
      return view
    }

    @Test("a tap picks or places; one finger draws from where it began, or aims and picks")
    func taps() {
      let events = EventLog()
      let view = layer(events)
      view.tap(at: CGPoint(x: 5, y: 6))
      #expect(events.take() == ["down (5.0, 6.0)", "up (5.0, 6.0)"])
      view.draws = true
      view.aim(.began, at: CGPoint(x: 1, y: 1))
      view.aim(.changed, at: CGPoint(x: 2, y: 2))
      view.aim(.cancelled, at: CGPoint(x: 9, y: 9))
      #expect(events.take() == ["down (1.0, 1.0)", "drag (2.0, 2.0)", "up (2.0, 2.0)"])
      view.draws = false
      view.aim(.began, at: CGPoint(x: 3, y: 3))
      view.aim(.changed, at: CGPoint(x: 4, y: 4))
      view.aim(.ended, at: CGPoint(x: 5, y: 5))
      #expect(events.take() == ["move (3.0, 3.0)", "move (4.0, 4.0)", "down (5.0, 5.0)"])
    }

    @Test("two fingers scroll the page within its content; Annotate outlines what comes under")
    func scrolling() {
      let events = EventLog()
      let view = layer(events)
      let page = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
      let scrollView = UIScrollView(frame: page.bounds)
      scrollView.contentSize = CGSize(width: 200, height: 1_000)
      page.addSubview(scrollView)
      view.page = page
      #expect(view.pageScrollView === scrollView)
      view.scroll(by: CGPoint(x: 0, y: -300), at: CGPoint(x: 10, y: 10))
      #expect(scrollView.contentOffset == CGPoint(x: 0, y: 300))
      #expect(events.take() == ["scrolled", "move (10.0, 10.0)"])
      view.scroll(by: CGPoint(x: 40, y: -5_000), at: .zero)
      #expect(scrollView.contentOffset == CGPoint(x: 0, y: 900))
      view.draws = true
      view.scroll(by: CGPoint(x: 0, y: 5_000), at: .zero)
      #expect(scrollView.contentOffset == .zero)
      #expect(events.take() == ["scrolled", "move (0.0, 0.0)", "scrolled"])
    }

    @Test("Apple Pencil's double tap undoes or switches back, as the system's setting asks")
    func pencil() {
      let events = EventLog()
      let view = layer(events)
      view.pencilDoubleTap(.switchEraser)
      view.pencilDoubleTap(.switchPrevious)
      view.pencilDoubleTap(.ignore)
      #expect(events.take() == ["undo", "previous"])
    }
  }

  /// What a layer reported, in order.
  @MainActor
  final class EventLog {
    private var events: [String] = []

    func add(_ event: String) { events.append(event) }

    /// The events so far, which it then forgets.
    func take() -> [String] {
      defer { events = [] }
      return events
    }
  }
#endif
