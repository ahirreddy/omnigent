#if os(macOS)
  import AppKit
  import ObjectiveC

  /// Stands in for `startDictation:` for this test process: the real one takes the microphone and
  /// shows the system's HUD on the person's screen. `NSApp.sendAction` is what the product calls.
  @MainActor
  enum DictationStub {
    static var count = 0
    /// Whether a responder takes the action; `false` is a Mac with dictation off.
    static var isAccepted = true
    private static var isInstalled = false

    private typealias SendAction =
      @convention(c) (NSApplication, Selector, Selector, Any?, Any?) -> Bool
    nonisolated(unsafe) private static var originalSendAction: IMP?

    static func install() {
      guard !isInstalled else { return }
      isInstalled = true
      let selector = #selector(NSApplication.sendAction(_:to:from:))
      guard let method = unsafe class_getInstanceMethod(NSApplication.self, selector) else {
        preconditionFailure("NSApplication has no sendAction:to:from:")
      }
      unsafe originalSendAction = unsafe method_getImplementation(method)
      let replacement: SendAction = { application, name, action, target, sender in
        if action == NSSelectorFromString("startDictation:") {
          return MainActor.assumeIsolated {
            guard Self.isAccepted else { return false }
            Self.count += 1
            return true
          }
        }
        let original = unsafe unsafeBitCast(Self.originalSendAction, to: SendAction.self)
        return original(application, name, action, target, sender)
      }
      unsafe method_setImplementation(method, unsafeBitCast(replacement, to: IMP.self))
    }
  }
#endif
