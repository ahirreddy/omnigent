#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// A view with linked text hosted off screen: where its links were found, and the addresses
  /// its links opened.
  @MainActor
  final class LinkedTextScreen {
    let screen: OffscreenWindow<AnyView>
    private let log: HostLog
    var opened: [String] { log.entries }

    init(_ view: some View, width: CGFloat = 700) {
      let log = HostLog()
      self.log = log
      screen = transcriptScreen(
        view.environment(
          \.openURL,
          OpenURLAction { url in
            log.add(url.absoluteString)
            return .handled
          }), width: width)
      screen.settle()
      NSCursor.arrow.set()
    }

    /// The views that hold link rectangles, top to bottom.
    var areas: [LinkPointerAreas.AreasView] {
      screen.allViews.compactMap { $0 as? LinkPointerAreas.AreasView }
        .sorted { frame(of: $0).minY < frame(of: $1).minY }
    }

    private func frame(of view: NSView) -> CGRect { view.convert(view.bounds, to: screen.host) }

    /// Every link rectangle on screen, from the screen's top left.
    var linkRects: [CGRect] {
      areas.flatMap { view in view.linkRects.map { view.convert($0, to: screen.host) } }
    }

    /// The view a click or a right click at `point` reaches.
    func viewUnder(_ point: CGPoint) -> NSView? {
      let host = screen.host
      return unsafe host.hitTest(host.convert(point, to: host.superview))
    }

    /// The addresses a click at `point` opened.
    func openedByClicking(_ point: CGPoint) throws -> [String] {
      log.clear()
      // A text clicked before keeps its editor up; each click starts from a text at rest.
      screen.window.makeFirstResponder(nil)
      try screen.click(point)
      screen.settle()
      return opened
    }

    /// Clicks just inside `link`'s ends and just past them: only the inside opens `address`, so
    /// the rectangle is the link's and no wider.
    func expectEdges(
      of link: CGRect, open address: String, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
      for inside in [link.minX + 2, link.midX, link.maxX - 2] {
        let opened = try openedByClicking(CGPoint(x: inside, y: link.midY))
        #expect(opened == [address], "at \(inside) in \(link)", sourceLocation: sourceLocation)
      }
      for outside in [link.minX - 6, link.maxX + 6] {
        let opened = try openedByClicking(CGPoint(x: outside, y: link.midY))
        #expect(opened.isEmpty, "at \(outside) beside \(link)", sourceLocation: sourceLocation)
      }
    }

    /// The pointer's move to `point`, as a tracking area reports it.
    func moved(to point: CGPoint) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: .mouseMoved, location: screen.host.convert(point, to: nil), modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: screen.window.windowNumber, context: nil, eventNumber: 1, clickCount: 0,
          pressure: 0))
    }
  }

  extension OffscreenWindow {
    /// Presses at `start`, drags to `end` and lets go, for a text that tracks the mouse inside
    /// its mouse down: the rest of the drag is posted from inside that tracking.
    func dragSelection(from start: CGPoint, to end: CGPoint) throws {
      func event(_ type: NSEvent.EventType, _ point: CGPoint, after delay: TimeInterval) throws
        -> NSEvent
      {
        let made = NSEvent.mouseEvent(
          with: type, location: host.convert(point, to: nil), modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime + delay,
          windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
          pressure: 1)
        guard let made else { throw OffscreenWindowError.eventUnavailable }
        return made
      }
      let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
      nonisolated(unsafe) let rest = [
        try event(.leftMouseDragged, middle, after: 0.03),
        try event(.leftMouseDragged, end, after: 0.04), try event(.leftMouseUp, end, after: 0.05),
      ]
      let post = Timer(timeInterval: 0.03, repeats: false) { _ in
        MainActor.assumeIsolated {
          for event in unsafe rest { NSApp.postEvent(event, atStart: false) }
        }
      }
      RunLoop.main.add(post, forMode: .common)
      window.makeKey()
      send(try event(.leftMouseDown, start, after: 0))
      post.invalidate()
      NSApp.discardEvents(matching: [.leftMouseDragged, .leftMouseUp], before: nil)
      settle()
    }
  }
#endif
