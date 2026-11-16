#if os(macOS)
  import AppKit
  import ObjectiveC
  import os

  /// Counts how often SwiftUI updates the AppKit view behind a selectable `Text`. SwiftUI's
  /// selectable text is an `NSTextField` subclass that is handed its string on every update, and
  /// a new string makes AppKit rebuild the window's cursor rectangles.
  nonisolated enum SelectableTextUpdates {
    enum Failure: Error, CustomStringConvertible {
      case noSelectableTextField

      var description: String {
        "SwiftUI's selectable text field class (\(SelectableTextUpdates.className)) is gone"
      }
    }

    /// The Objective-C name of SwiftUI's selectable text field.
    static let className = "_TtC7SwiftUI18SelectionTextField"

    private struct State {
      var isInstalled = false
      var isRecording = false
      var count = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Runs `update` and returns how many selectable texts were handed their string meanwhile.
    @MainActor
    static func recording(_ update: () throws -> Void) throws -> Int {
      try install()
      state.withLock {
        $0.isRecording = true
        $0.count = 0
      }
      defer { state.withLock { $0.isRecording = false } }
      try update()
      return state.withLock { $0.count }
    }

    private typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void

    /// Wraps the field's string setter once per process; it counts while recording.
    private static func install() throws {
      guard !state.withLock({ $0.isInstalled }) else { return }
      guard let field = NSClassFromString(className) else { throw Failure.noSelectableTextField }
      let selector = #selector(setter: NSControl.attributedStringValue)
      guard let method = unsafe class_getInstanceMethod(field, selector) else {
        throw Failure.noSelectableTextField
      }
      let original = unsafe unsafeBitCast(method_getImplementation(method), to: Setter.self)
      let counting: @convention(block) (AnyObject, AnyObject?) -> Void = { field, string in
        state.withLock { if $0.isRecording { $0.count += 1 } }
        original(field, selector, string)
      }
      unsafe class_replaceMethod(
        field, selector, imp_implementationWithBlock(counting), method_getTypeEncoding(method))
      state.withLock { $0.isInstalled = true }
    }
  }
#endif
