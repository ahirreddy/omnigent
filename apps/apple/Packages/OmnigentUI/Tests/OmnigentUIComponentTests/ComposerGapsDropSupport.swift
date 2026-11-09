#if os(macOS)
  import AppKit
  import OmnigentViewTesting

  /// What AppKit tells a drop target about a drag. No system drag exists: a test hands this to the
  /// hosting view's `NSDraggingDestination` methods, with its own named pasteboard.
  @MainActor
  final class ScriptedDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation = .every
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(window: NSWindow, location: NSPoint, pasteboard: NSPasteboard) {
      draggingDestinationWindow = window
      draggingLocation = location
      draggingPasteboard = pasteboard
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    func enumerateDraggingItems(
      options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
      classes classArray: [AnyClass],
      searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
      using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}

    // AppKit's own dragging info answers this; SwiftUI's drop target asks it.
    // swiftlint:disable:next identifier_name
    @objc func _lastDragDestinationOperation() -> UInt { lastOperation }
    var lastOperation: UInt = 0
  }

  extension OffscreenWindow {
    /// A pasteboard private to one test, holding these items.
    func dragPasteboard(_ write: (NSPasteboard) -> Void) -> NSPasteboard {
      let pasteboard = NSPasteboard(name: NSPasteboard.Name("omnigent-test-\(UUID().uuidString)"))
      pasteboard.clearContents()
      write(pasteboard)
      return pasteboard
    }

    /// Whether `condition` comes true within ten seconds, for work a view does in its own tasks:
    /// a dropped item arrives from NSItemProvider however long the machine lets it.
    func eventually(_ condition: @MainActor () throws -> Bool) async throws -> Bool {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(10))
      while clock.now < deadline {
        if try condition() { return true }
        try await Task.sleep(for: .milliseconds(20))
        settle(0.01)
      }
      return try condition()
    }

    /// The middle of the editor, where a drop or a click lands on the composer.
    var editorCenter: CGPoint? {
      guard let textView, let scroll = textView.enclosingScrollView else { return nil }
      let frame = scroll.convert(scroll.bounds, to: host)
      return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The topmost drop target under a point, as AppKit picks it.
    private func dropTarget(at point: CGPoint) -> NSView? {
      allViews.last { view in
        !view.registeredDraggedTypes.isEmpty && !view.isHiddenOrHasHiddenAncestor
          && view.convert(view.bounds, to: host).contains(point)
      }
    }

    /// Enters the target at `point` with this pasteboard, as a drag crossing into it does.
    func beginScriptedDrop(
      at point: CGPoint, pasteboard: NSPasteboard
    ) throws -> ScriptedDrop {
      guard let target = dropTarget(at: point) else {
        throw OffscreenWindowError.notFound("a drop target at \(point)")
      }
      let info = ScriptedDraggingInfo(
        window: window, location: host.convert(point, to: nil), pasteboard: pasteboard)
      let operation = target.draggingEntered(info)
      info.lastOperation = operation.rawValue
      settle(0.05)
      info.lastOperation = target.draggingUpdated(info).rawValue
      settle(0.05)
      return ScriptedDrop(target: target, info: info, operation: operation)
    }

    /// Lets go of a drag.
    @discardableResult
    func finishScriptedDrop(_ drop: ScriptedDrop) -> Bool {
      let accepted =
        drop.target.prepareForDragOperation(drop.info)
        && drop.target.performDragOperation(drop.info)
      drop.target.concludeDragOperation(drop.info)
      settle(0.05)
      return accepted
    }

    /// The pointer leaves the target during a drag.
    func exitScriptedDrop(_ drop: ScriptedDrop) {
      drop.target.draggingExited(drop.info)
      settle(0.05)
    }
  }

  /// A drag over a drop target.
  @MainActor
  struct ScriptedDrop {
    let target: NSView
    let info: ScriptedDraggingInfo
    let operation: NSDragOperation
  }
#endif
