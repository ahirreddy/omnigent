#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI

  /// Input a pointer or trackpad would cause, sent to a hosted view without moving the real pointer
  /// or starting a system drag.
  extension OffscreenWindow {
    /// Sends an event from a run loop of its own, as `OffscreenWindow` does for a click.
    func send(_ event: NSEvent, to window: NSWindow? = nil) {
      nonisolated(unsafe) let sent = event
      let target = window ?? activeWindow
      CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
        MainActor.assumeIsolated { target.sendEvent(unsafe sent) }
        CFRunLoopStop(CFRunLoopGetMain())
      }
      _ = CFRunLoopRunInMode(.defaultMode, .greatestFiniteMagnitude, false)
    }

    /// Clicks a button in the open popover by its place from the right: events go to the popover's
    /// own window, which `OffscreenWindow.click` doesn't address.
    func clickPopoverButton(fromRight index: Int) throws {
      guard let popover = popoverWindow, let root = popover.contentView else {
        throw OffscreenWindowError.notFound("popover")
      }
      var pending = [root]
      var frames: [CGRect] = []
      while let view = pending.popLast() {
        if String(describing: Swift.type(of: view)) == "KeyViewProxy" {
          frames.append(view.convert(view.bounds, to: nil))
        }
        pending.append(contentsOf: view.subviews)
      }
      let ordered = frames.sorted { $0.minX > $1.minX }
      guard ordered.indices.contains(index) else {
        throw OffscreenWindowError.notFound("popover button \(index) of \(ordered.count)")
      }
      let location = CGPoint(x: ordered[index].midX, y: ordered[index].midY)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let made = NSEvent.mouseEvent(
          with: type, location: location, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popover.windowNumber,
          context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
        guard let made else { throw OffscreenWindowError.eventUnavailable }
        send(made, to: popover)
      }
      settle(0.2)
    }

    /// Presses at `start`, moves through to `end` and lets go, as a gesture sees a mouse drag.
    func dragGesture(from start: CGPoint, to end: CGPoint, steps: Int = 4) throws {
      let root = activeWindow.contentView ?? host
      func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
        let made = NSEvent.mouseEvent(
          with: type, location: root.convert(point, to: nil), modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: activeWindow.windowNumber,
          context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
        guard let made else { throw OffscreenWindowError.eventUnavailable }
        return made
      }
      send(try event(.leftMouseDown, start))
      settle(0.02)
      for step in 1...steps {
        let fraction = CGFloat(step) / CGFloat(steps)
        let point = CGPoint(
          x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
        send(try event(.leftMouseDragged, point))
        settle(0.02)
      }
      send(try event(.leftMouseUp, end))
      settle()
    }
  }

  /// A trackpad pinch as AppKit reports one; only an event like this reaches `MagnifyGesture`,
  /// since AppKit won't build one for a window off every display.
  nonisolated final class PinchEventStub: NSEvent {
    nonisolated(unsafe) private var target: NSWindow?
    nonisolated(unsafe) private var location = NSPoint.zero
    nonisolated(unsafe) private var pinchPhase: NSEvent.Phase = []
    nonisolated(unsafe) private var amount: CGFloat = 0

    convenience init(window: NSWindow, location: NSPoint, phase: NSEvent.Phase, amount: CGFloat) {
      self.init()
      unsafe target = window
      unsafe self.location = location
      unsafe pinchPhase = phase
      unsafe self.amount = amount
    }

    override var type: NSEvent.EventType { .magnify }
    override var window: NSWindow? { unsafe target }
    override var windowNumber: Int { unsafe target?.windowNumber ?? 0 }
    override var locationInWindow: NSPoint { unsafe location }
    override var phase: NSEvent.Phase { unsafe pinchPhase }
    override var magnification: CGFloat { unsafe amount }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
  }

  extension OffscreenWindow {
    /// Pinches at a point, each amount adding to the magnification as the fingers move.
    func pinch(at point: CGPoint, amounts: [CGFloat]) {
      let location = host.convert(point, to: nil)
      let phases =
        [(NSEvent.Phase.began, CGFloat(0))] + amounts.map { (.changed, $0) } + [(.ended, 0)]
      for (phase, amount) in phases {
        send(PinchEventStub(window: window, location: location, phase: phase, amount: amount))
        settle(0.02)
      }
    }

    /// The drop destinations under a point, innermost last.
    func dropDestinations(at point: CGPoint) -> [NSView] {
      let root = activeWindow.contentView ?? host
      return allViews.filter {
        !$0.registeredDraggedTypes.isEmpty && $0.convert($0.bounds, to: root).contains(point)
      }
    }

    /// Brings a drag carrying `text` over a point, as AppKit tells a destination it arrived.
    func dragEnters(_ text: String, at point: CGPoint) throws -> (NSView, DraggingInfoStub) {
      guard let destination = dropDestinations(at: point).last else {
        throw OffscreenWindowError.notFound("a drop destination")
      }
      let root = activeWindow.contentView ?? host
      let info = DraggingInfoStub(
        window: window, location: root.convert(point, to: nil), string: text)
      _ = destination.draggingEntered(info)
      settle(0.02)
      _ = destination.draggingUpdated(info)
      settle(0.02)
      return (destination, info)
    }

    /// Lets the drag go and waits for what it delivers.
    func dragDrops(_ arrival: (NSView, DraggingInfoStub)) async throws {
      let (destination, info) = arrival
      _ = destination.prepareForDragOperation(info)
      _ = destination.performDragOperation(info)
      try await letTasksRun(passes: 12)
      destination.concludeDragOperation(info)
      try await letTasksRun()
    }

    /// Drags `text` onto a point and lets go.
    func drop(_ text: String, at point: CGPoint) async throws {
      try await dragDrops(try dragEnters(text, at: point))
    }

    /// Tells a scroll view's observers a user scroll began or ended, as a trackpad gesture does.
    func liveScroll(_ scrollView: NSScrollView, began: Bool) {
      let name =
        began
        ? NSScrollView.willStartLiveScrollNotification : NSScrollView.didEndLiveScrollNotification
      NotificationCenter.default.post(name: name, object: scrollView)
      settle(0.03)
    }
  }

  /// A drag in progress as a drop destination is asked about it, with no drag session behind it.
  @MainActor
  final class DraggingInfoStub: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    let draggingPasteboard: NSPasteboard
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(window: NSWindow?, location: NSPoint, string: String) {
      draggingDestinationWindow = window
      draggingLocation = location
      draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("DraggingInfoStub-\(UUID())"))
      draggingPasteboard.clearContents()
      draggingPasteboard.setString(string, forType: .string)
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    func enumerateDraggingItems(
      options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
      classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
      using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
  }
#endif
