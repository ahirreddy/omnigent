import AppKit
import Foundation
import SwiftUI

@testable import OmnigentWebLayer

/// Hosts views in a window that is never shown or activated.
@MainActor
enum Offscreen {
  static func window(size: CGSize = CGSize(width: 400, height: 300)) -> NSWindow {
    _ = NSApplication.shared
    return NSWindow(
      contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
      defer: false)
  }

  /// Draws `view` into a bitmap; returns how many points it covered.
  @discardableResult
  static func draw(_ view: NSView) -> Int {
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap.pixelsWide * bitmap.pixelsHigh
  }

  static func keyEvent(
    _ type: NSEvent.EventType = .keyDown, characters: String = "a", keyCode: UInt16 = 0,
    flags: NSEvent.ModifierFlags = [], window: NSWindow? = nil
  ) throws -> NSEvent {
    let event = NSEvent.keyEvent(
      with: type, location: .zero, modifierFlags: flags, timestamp: 0,
      windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
    return try unwrap(event)
  }

  static func mouseEvent(_ type: NSEvent.EventType, window: NSWindow? = nil) throws -> NSEvent {
    let event = NSEvent.mouseEvent(
      with: type, location: CGPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0,
      windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
      pressure: 1)
    return try unwrap(event)
  }

  private static func unwrap(_ event: NSEvent?) throws -> NSEvent {
    guard let event else { throw WebLayerError.invalidArgument("NSEvent was refused") }
    return event
  }
}

/// Ends a responder chain, which would otherwise beep at keys nobody took.
final class SilentResponder: NSResponder {
  var keyDowns = 0
  override func keyDown(with event: NSEvent) { keyDowns += 1 }
  override func keyUp(with event: NSEvent) {}
  override func noResponder(for eventSelector: Selector) {}
}

/// What AppKit passes while a drag hovers over a view, without starting one.
final class FakeDragInfo: NSObject, NSDraggingInfo {
  let draggingPasteboard: NSPasteboard
  var draggingSourceOperationMask: NSDragOperation
  let draggingLocation = NSPoint(x: 10, y: 20)
  let draggedImageLocation = NSPoint.zero
  let draggingDestinationWindow: NSWindow? = nil
  let draggedImage: NSImage? = nil
  let draggingSource: Any? = nil
  let draggingSequenceNumber = 1
  var draggingFormation = NSDraggingFormation.none
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 1
  let springLoadingHighlight = NSSpringLoadingHighlight.none

  init(pasteboard: NSPasteboard, operations: NSDragOperation = [.copy, .move]) {
    draggingPasteboard = pasteboard
    draggingSourceOperationMask = operations
  }

  func slideDraggedImage(to screenPoint: NSPoint) {}
  func enumerateDraggingItems(
    options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
    using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {}
  func resetSpringLoading() {}
}
