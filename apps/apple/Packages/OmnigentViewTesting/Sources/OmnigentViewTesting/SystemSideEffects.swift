// These replace Objective-C methods, so their signatures use its reference types.
// swiftlint:disable legacy_objc_type

#if os(macOS)
  public import AppKit
  import ObjectiveC
  import os

  /// Keeps a test's clicks from reaching the person using this Mac: the clipboard, the browser,
  /// Finder, modal panels, focus, new windows and quitting all stop at a recorder instead.
  ///
  /// `OffscreenWindow` installs this for its process. A test that reaches such code without a
  /// window calls `install()` itself. Assert on what was recorded after `reset()`.
  public enum SystemSideEffects {
    /// What product code tried to do.
    public struct Record: Equatable, Sendable {
      /// URLs and applications it tried to open.
      public var openedURLs: [URL] = []
      /// Files it tried to reveal in Finder.
      public var revealedURLs: [URL] = []
      /// Titles of the windows it tried to show.
      public var shownWindowTitles: [String] = []
      /// Messages of the alerts it tried to show.
      public var alertMessages: [String] = []
      /// How many open or save panels it tried to show.
      public var panelCount = 0
      /// How many menus it tried to pop up.
      public var poppedUpMenuCount = 0
      /// How many times it tried to bring the app forward.
      public var activationCount = 0
      /// How many times it tried to quit the app.
      public var terminationCount = 0
    }

    private typealias OpenedHandler = @convention(block) (NSRunningApplication?, NSError?) -> Void
    typealias ResponseHandler = @convention(block) (Int) -> Void
    private typealias OpenConfigured =
      @convention(c) (
        NSWorkspace, Selector, NSURL, NSWorkspace.OpenConfiguration, OpenedHandler?
      ) -> Void
    private typealias OpenWith =
      @convention(c) (
        NSWorkspace, Selector, NSArray, NSURL, NSWorkspace.OpenConfiguration, OpenedHandler?
      ) -> Void
    private typealias AlertSheet =
      @convention(c) (NSAlert, Selector, NSWindow?, ResponseHandler?) -> Void
    private typealias WindowInit =
      @convention(c) (NSWindow, Selector, NSRect, UInt, UInt, Bool) -> NSWindow
    private typealias SetAlpha = @convention(c) (NSWindow, Selector, CGFloat) -> Void
    private typealias MenuPopUp =
      @convention(c) (NSMenu, Selector, NSMenuItem?, NSPoint, NSView?) -> Bool

    struct State {
      var record = Record()
      var alertResponse = NSApplication.ModalResponse.alertFirstButtonReturn
      var panelResponse = NSApplication.ModalResponse.cancel
      var panelURL: URL?
      var opensFail = false
    }

    static let state = OSAllocatedUnfairLock(initialState: State())
    private nonisolated(unsafe) static var originalWindowInit: IMP?
    private nonisolated(unsafe) static var originalSetAlpha: IMP?
    nonisolated(unsafe) static var originalPanelURL: IMP?
    private static let installation = OSAllocatedUnfairLock(initialState: false)

    /// A private clipboard standing in for `NSPasteboard.general`, unique to this process.
    public static var pasteboard: NSPasteboard {
      NSPasteboard(name: NSPasteboard.Name("OmnigentViewTesting-\(getpid())"))
    }

    /// Everything recorded since the last `reset()`.
    public static var record: Record { state.withLock { $0.record } }

    /// Forgets what was recorded, clears the private clipboard and restores default answers.
    public static func reset() {
      state.withLock { $0 = State() }
      pasteboard.clearContents()
    }

    /// Sets how alerts and panels answer. Alerts default to their first button, panels to Cancel.
    /// - Parameters:
    ///   - alert: What an alert returns.
    ///   - panel: What an open or save panel returns.
    ///   - panelURL: The file an open or save panel holds, as if the person chose it.
    ///   - opensFail: Whether opening a URL or app reports a failure instead of succeeding.
    public static func answer(
      alert: NSApplication.ModalResponse = .alertFirstButtonReturn,
      panel: NSApplication.ModalResponse = .cancel,
      panelURL: URL? = nil,
      opensFail: Bool = false
    ) {
      state.withLock {
        $0.alertResponse = alert
        $0.panelResponse = panel
        $0.panelURL = panelURL
        $0.opensFail = opensFail
      }
    }

    /// Replaces the system entry points for this process, once. They stay replaced until it exits.
    public static func install() {
      let isFirst = installation.withLock { installed in
        defer { installed = true }
        return !installed
      }
      guard isFirst else { return }
      installFalsePassGuard()
      requireShield(isRequested: RunnerLoopShield.isRequested)
      installPasteboard()
      installWorkspace()
      installPanels()
      installAlerts()
      installApplication()
      installWindowsAndMenus()
      installInvisibleWindows()
    }

    static func note(_ change: (inout Record) -> Void) {
      state.withLockUnchecked { change(&$0.record) }
    }

    /// Ends the test process as a failed run, when tests can't safely go on. It exits rather than
    /// crashes, so a test can watch it happen.
    /// - Parameter message: Why, for the run's log.
    static func failRun(_ message: String) -> Never {
      FileHandle.standardError.write(Data("\(message)\n".utf8))
      exit(70)
    }

    /// Fails the run unless the shield was asked for: a stopped run loop would end the run.
    /// - Parameter isRequested: Whether the test bundle's load asked for it.
    static func requireShield(isRequested: Bool) {
      guard isRequested else { failRun("The runner loop shield didn't start.") }
    }

    /// The method to replace. A selector this SDK lacks must fail the test run, not leak through.
    /// - Parameters:
    ///   - owner: The class.
    ///   - name: The selector's name.
    ///   - isClassMethod: Whether it is a class method.
    /// - Returns: The method.
    static func method(_ owner: AnyClass, _ name: String, isClassMethod: Bool = false) -> Method {
      let selector = NSSelectorFromString(name)
      let found =
        unsafe isClassMethod
        ? class_getClassMethod(owner, selector) : class_getInstanceMethod(owner, selector)
      guard let found = unsafe found else { failRun("SystemSideEffects: \(owner) has no \(name)") }
      return unsafe found
    }

    /// Swaps a method's body for a C function taking the receiver and selector first.
    static func replace<Function>(
      _ owner: AnyClass, _ name: String, isClassMethod: Bool = false, with function: Function
    ) {
      let found = unsafe method(owner, name, isClassMethod: isClassMethod)
      unsafe method_setImplementation(found, unsafeBitCast(function, to: IMP.self))
    }

    private static func installPasteboard() {
      let general: @convention(c) (AnyClass, Selector) -> NSPasteboard = { _, _ in Self.pasteboard }
      replace(NSPasteboard.self, "generalPasteboard", isClassMethod: true, with: general)
    }

    private static func installWorkspace() {
      let open: @convention(c) (NSWorkspace, Selector, NSURL) -> Bool = { _, _, url in
        Self.note { $0.openedURLs.append(url as URL) }
        return true
      }
      replace(NSWorkspace.self, "openURL:", with: open)
      let openConfigured: OpenConfigured = { _, _, url, _, done in
        Self.note { $0.openedURLs.append(url as URL) }
        guard !Self.state.withLock({ $0.opensFail }) else {
          done?(nil, NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError))
          return
        }
        // Swift's async form of this call crashes on no app and no error.
        done?(NSRunningApplication.current, nil)
      }
      replace(NSWorkspace.self, "openURL:configuration:completionHandler:", with: openConfigured)
      replace(
        NSWorkspace.self, "openApplicationAtURL:configuration:completionHandler:",
        with: openConfigured)
      let openWith: OpenWith = { _, _, urls, application, _, done in
        Self.note { $0.openedURLs.append(contentsOf: urls.compactMap { $0 as? URL }) }
        Self.note { $0.openedURLs.append(application as URL) }
        done?(NSRunningApplication.current, nil)
      }
      replace(
        NSWorkspace.self, "openURLs:withApplicationAtURL:configuration:completionHandler:",
        with: openWith)
      let reveal: @convention(c) (NSWorkspace, Selector, NSArray) -> Void = { _, _, urls in
        Self.note { $0.revealedURLs.append(contentsOf: urls.compactMap { $0 as? URL }) }
      }
      replace(NSWorkspace.self, "activateFileViewerSelectingURLs:", with: reveal)
    }

    private static func installAlerts() {
      let run: @convention(c) (NSAlert, Selector) -> Int = { alert, _ in
        let message = MainActor.assumeIsolated { alert.messageText }
        Self.note { $0.alertMessages.append(message) }
        return Self.state.withLock { $0.alertResponse.rawValue }
      }
      replace(NSAlert.self, "runModal", with: run)
      let sheet: AlertSheet = { alert, _, _, done in
        let message = MainActor.assumeIsolated { alert.messageText }
        Self.note { $0.alertMessages.append(message) }
        done?(Self.state.withLock { $0.alertResponse.rawValue })
      }
      replace(NSAlert.self, "beginSheetModalForWindow:completionHandler:", with: sheet)
    }

    private static func installApplication() {
      // A destructive button ignores clicks in an inactive app, and a test never activates.
      let isActive: @convention(c) (NSApplication, Selector) -> Bool = { _, _ in true }
      replace(NSApplication.self, "isActive", with: isActive)
      let terminate: @convention(c) (NSApplication, Selector, AnyObject?) -> Void = { _, _, _ in
        Self.note { $0.terminationCount += 1 }
      }
      replace(NSApplication.self, "terminate:", with: terminate)
      let activate: @convention(c) (NSApplication, Selector) -> Void = { _, _ in
        Self.note { $0.activationCount += 1 }
      }
      replace(NSApplication.self, "activate", with: activate)
      let activateIgnoring: @convention(c) (NSApplication, Selector, Bool) -> Void = { _, _, _ in
        Self.note { $0.activationCount += 1 }
      }
      replace(NSApplication.self, "activateIgnoringOtherApps:", with: activateIgnoring)
    }

    private static func installWindowsAndMenus() {
      // `OffscreenWindow` uses `orderFrontRegardless`, which stays real.
      let show: @convention(c) (NSWindow, Selector, AnyObject?) -> Void = { window, _, _ in
        let title = MainActor.assumeIsolated { window.title }
        Self.note { $0.shownWindowTitles.append(title) }
      }
      replace(NSWindow.self, "makeKeyAndOrderFront:", with: show)
      replace(NSWindow.self, "orderFront:", with: show)
      let popUp: MenuPopUp = { _, _, _, _, _ in
        Self.note { $0.poppedUpMenuCount += 1 }
        return false
      }
      replace(NSMenu.self, "popUpMenuPositioningItem:atLocation:inView:", with: popUp)
    }

    /// Whether a process exit came from the test runner's run loop returning, not from the runner
    /// deciding the result: AppKit can stop that loop, and it would then exit 0 mid-run.
    /// - Parameter callStack: The symbols of the exiting call stack.
    /// - Returns: Whether the exit ends the test run early.
    static func endsRunEarly(callStack: [String]) -> Bool {
      let fromRunLoop = callStack.contains { $0.contains("swift_task_asyncMainDrainQueue") }
      let fromRunner = callStack.contains { $0.contains("SwiftPMGeneratedTestRunner") }
      return fromRunLoop && !fromRunner
    }

    /// Turns an early exit into a failure, so unrun tests can't count as a pass.
    private static func installFalsePassGuard() {
      atexit { Self.endRunIfEarly(callStack: Thread.callStackSymbols) }
    }

    /// Fails the run when an exit ended it early, and otherwise lets the exit go on.
    /// - Parameter callStack: The symbols of the exiting call stack.
    static func endRunIfEarly(callStack: [String]) {
      guard endsRunEarly(callStack: callStack) else { return }
      // coverage:off _exit skips coverage's write at exit; the test falsePassFailsTheRun runs this
      let message = "FALSE PASS: the test runner's run loop stopped mid-run. Failing the run.\n"
      FileHandle.standardError.write(Data(message.utf8))
      _exit(70)
    }
    // coverage:on

    /// Every window in the process is transparent and takes no real clicks from birth, whatever
    /// shows it: sheets, dialogs and menus can move on screen, and tests still reach them by event.
    private static func installInvisibleWindows() {
      let create = unsafe method(NSWindow.self, "initWithContentRect:styleMask:backing:defer:")
      unsafe originalWindowInit = method_getImplementation(create)
      let makeInvisible: WindowInit = { window, selector, frame, style, backing, deferred in
        let original = unsafe unsafeBitCast(Self.originalWindowInit, to: WindowInit.self)
        let created = original(window, selector, frame, style, backing, deferred)
        MainActor.assumeIsolated {
          created.alphaValue = 0
          created.ignoresMouseEvents = true
          // Ordering in or out animates, and the animation's end stops whichever run loop is
          // running. On the test runner's own loop that ends the process.
          created.animationBehavior = .none
        }
        return created
      }
      unsafe method_setImplementation(create, unsafeBitCast(makeInvisible, to: IMP.self))

      let setAlpha = unsafe method(NSWindow.self, "setAlphaValue:")
      unsafe originalSetAlpha = method_getImplementation(setAlpha)
      let keepTransparent: SetAlpha = { window, selector, _ in
        let original = unsafe unsafeBitCast(Self.originalSetAlpha, to: SetAlpha.self)
        original(window, selector, 0)
      }
      unsafe method_setImplementation(setAlpha, unsafeBitCast(keepTransparent, to: IMP.self))
    }
  }
#endif

// swiftlint:enable legacy_objc_type
