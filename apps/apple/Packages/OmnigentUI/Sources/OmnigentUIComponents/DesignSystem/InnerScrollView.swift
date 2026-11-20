#if os(macOS)
  import AppKit

  /// A scroll view that ``ScrollGestureRouter`` routes wheel and trackpad events between.
  protocol RoutedScroller: NSView {
    /// The outermost scroller takes every gesture the scrollers inside it don't.
    var isOutermost: Bool { get }
    /// Whether this view can scroll the way `event`, a gesture's first move or a wheel's step,
    /// goes along its larger axis.
    func accepts(_ event: NSEvent) -> Bool
    /// Scrolls for `event`, as AppKit's scroll view does.
    func scroll(for event: NSEvent)
  }

  /// Sends each wheel and trackpad event to the scroller its gesture belongs to: the innermost
  /// one under the pointer where the gesture began that can scroll its way. The rest of the
  /// gesture and its momentum follow it there, though AppKit hands each event to whatever view
  /// the scroll has since moved under the pointer.
  enum ScrollGestureRouter {
    private enum Stage {
      /// No gesture is in progress.
      case idle
      /// It began without moving: its first event waits for one that shows which way it goes.
      case undecided(NSEvent)
      /// The fingers are down.
      case touching
      /// The fingers lifted at this time; momentum may follow at once.
      case lifted(TimeInterval)
      /// The gesture's momentum.
      case coasting
    }

    private enum Route {
      /// This scroller takes the event, after a held first event.
      case here(replaying: NSEvent?)
      /// The scroller that owns the gesture takes it.
      case owner(any RoutedScroller)
      /// The next responder takes it, and the scroller around this one.
      case onward
      /// Nothing scrolls for it.
      case nowhere
    }

    private static var stage = Stage.idle
    private static weak var owner: (any RoutedScroller)?

    /// The longest wait from a gesture's lift to its momentum's first event.
    static let momentumGap: TimeInterval = 0.25

    /// Delivers `event`, which AppKit sent to `scroller`, to the scroller its gesture belongs to.
    static func deliver(_ event: NSEvent, to scroller: some RoutedScroller) {
      switch route(event, reaching: scroller) {
      case .here(let held):
        if let held { scroller.scroll(for: held) }
        scroller.scroll(for: event)
      case .owner(let owner):
        owner.scroll(for: event)
      case .onward:
        // AppKit declares `nextResponder` unowned(unsafe); it is only messaged here.
        unsafe scroller.nextResponder?.scrollWheel(with: event)
      case .nowhere:
        break
      }
    }

    private static func route(_ event: NSEvent, reaching scroller: any RoutedScroller) -> Route {
      // A mouse wheel's step belongs to no gesture: the innermost scroller that can take it does.
      if event.phase.isEmpty && event.momentumPhase.isEmpty {
        end()
        return scroller.isOutermost || scroller.accepts(event) ? .here(replaying: nil) : .onward
      }
      if event.phase.contains(.mayBegin) {
        end()
        return scroller.isOutermost ? .here(replaying: nil) : .onward
      }
      if event.phase.contains(.began) {
        end()
        guard moves(event) else {
          stage = .undecided(event)
          return .nowhere
        }
        return claim(event, by: scroller, replaying: nil)
      }
      if case .undecided(let began) = stage {
        guard event.phase.contains(.ended) || event.phase.contains(.cancelled) else {
          return moves(event) ? claim(event, by: scroller, replaying: began) : .nowhere
        }
        // It lifted without moving: nothing scrolled.
        end()
        return .nowhere
      }
      if let owner = liveOwner(beside: scroller), continues(event) {
        advance(past: event)
        return owner === scroller ? .here(replaying: nil) : .owner(owner)
      }
      // The gesture began where no scroller here saw it, or its owner has gone.
      end()
      guard scroller.isOutermost else { return .onward }
      owner = scroller
      advance(past: event)
      return .here(replaying: nil)
    }

    /// The gesture goes to `scroller` if it can scroll the way `event` moves, else on outward.
    private static func claim(
      _ event: NSEvent, by scroller: any RoutedScroller, replaying began: NSEvent?
    ) -> Route {
      guard scroller.isOutermost || scroller.accepts(event) else { return .onward }
      owner = scroller
      stage = .touching
      return .here(replaying: began)
    }

    private static func moves(_ event: NSEvent) -> Bool {
      event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0
    }

    /// The gesture's owner, while it is in the window `scroller` is in.
    private static func liveOwner(beside scroller: any RoutedScroller) -> (any RoutedScroller)? {
      // AppKit declares `window` unowned(unsafe); it is only compared here.
      guard let owner, let window = unsafe owner.window, unsafe window === scroller.window else {
        return nil
      }
      return owner
    }

    /// Whether `event` is the next step of the gesture in progress.
    private static func continues(_ event: NSEvent) -> Bool {
      let momentum = event.momentumPhase
      switch stage {
      case .touching:
        return momentum.isEmpty
      case .lifted(let time):
        return momentum.contains(.began) && event.timestamp - time <= momentumGap
      case .coasting:
        return !momentum.isEmpty && !momentum.contains(.began)
      case .idle, .undecided:
        return false
      }
    }

    /// Moves the gesture on to the stage `event` leaves it in.
    private static func advance(past event: NSEvent) {
      let momentum = event.momentumPhase
      if momentum.contains(.ended) || momentum.contains(.cancelled) {
        end()
      } else if !momentum.isEmpty {
        stage = .coasting
      } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
        stage = .lifted(event.timestamp)
      } else {
        stage = .touching
      }
    }

    private static func end() {
      stage = .idle
      owner = nil
    }
  }

  /// A scroll view inside another, such as a code block's or a table's in a transcript row. It
  /// takes a gesture only when the gesture began over it along an axis it can still scroll, and a
  /// wheel's step only when it can scroll that way; the scroll view around it takes the rest,
  /// momentum included.
  class InnerScrollView: NSScrollView, RoutedScroller {
    var isOutermost: Bool { false }

    override func scrollWheel(with event: NSEvent) {
      ScrollGestureRouter.deliver(event, to: self)
    }

    func scroll(for event: NSEvent) {
      super.scrollWheel(with: event)
    }

    /// Vertically, only while the content can move that way: one at its edge hands the gesture
    /// out. Sideways, a gesture takes any content wider than the view, to bounce at its edge.
    func accepts(_ event: NSEvent) -> Bool {
      let across = event.scrollingDeltaX
      let down = event.scrollingDeltaY
      if abs(down) >= abs(across) { return hasRoom(vertically: down) }
      return event.phase.isEmpty ? hasRoom(horizontally: across) : overflowsHorizontally
    }

    private var overflowsHorizontally: Bool {
      guard let document = documentView else { return false }
      return document.frame.width > contentView.bounds.width + 0.5
    }

    /// Whether the content can move `delta`'s way sideways; a positive delta shows its left.
    private func hasRoom(horizontally delta: CGFloat) -> Bool {
      guard let document = documentView, delta != 0 else { return false }
      let visible = contentView.bounds
      let content = document.frame
      return delta > 0 ? visible.minX > content.minX + 0.5 : visible.maxX < content.maxX - 0.5
    }

    /// Whether the content can move `delta`'s way up or down; a positive delta shows its top.
    private func hasRoom(vertically delta: CGFloat) -> Bool {
      guard let document = documentView, delta != 0 else { return false }
      let visible = contentView.bounds
      let content = document.frame
      // A flipped clip view has the content's top at its smallest y.
      let towardSmallerY = (delta > 0) == contentView.isFlipped
      return towardSmallerY
        ? visible.minY > content.minY + 0.5 : visible.maxY < content.maxY - 0.5
    }
  }
#endif
