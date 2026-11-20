public import AppKit
public import SwiftUI

/// The floating New Agent panel: a small window over whatever app is in front, on the pointer's
/// display, that takes the keyboard without making Omnigent the active app (as Spotlight does).
/// Escape, its Close button and Command-W hide it, keeping what it holds; so does going to an
/// Omnigent window. Showing it again while it is up gives it the keyboard back. The app keeps
/// one for its lifetime, so its window observers are never removed.
public final class FloatingPanelController {
  /// The panel's width; its height follows its content.
  public static let width: CGFloat = 680

  private var panel: FloatingPanelWindow?
  private var observers: [any NSObjectProtocol] = []
  private var escapeMonitor: Any?

  /// Creates a controller; the panel is built on the first ``show(content:)``.
  public init() {}

  /// Whether the panel is on screen.
  public var isVisible: Bool { panel?.isVisible == true }

  /// Shows the panel over the front app, building it with `content` the first time, and gives
  /// it the keyboard. A panel already up only takes the keyboard back.
  /// - Parameter content: The panel's content, kept between shows.
  public func show(content: () -> AnyView) {
    let panel = panel ?? makePanel(content: content())
    if !panel.isVisible {
      panel.setFrameOrigin(Self.origin(size: panel.frame.size, on: Self.pointerScreen()))
    }
    panel.orderFrontRegardless()
    panel.makeKey()
  }

  /// Replaces what the panel shows, as after a launch that clears it.
  /// - Parameter content: The new content.
  public func replaceContent(_ content: AnyView) {
    panel?.contentViewController = Self.hosting(content)
  }

  /// Hides the panel, keeping its content for the next show.
  public func hide() {
    panel?.orderOut(nil)
  }

  private func makePanel(content: AnyView) -> FloatingPanelWindow {
    let panel = FloatingPanelWindow(
      contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 240))
    panel.contentViewController = Self.hosting(content)
    panel.onHide = { [weak self] in self?.hide() }
    self.panel = panel
    observe(panel)
    return panel
  }

  private static func hosting(_ content: AnyView) -> NSViewController {
    let hosting = NSHostingController(rootView: content.frame(width: width))
    // The panel's height follows the composer as it grows.
    hosting.sizingOptions = [.preferredContentSize]
    return hosting
  }

  /// Hides the panel when one of Omnigent's own windows takes the keyboard (not an open or save
  /// panel the composer showed), and when Escape is pressed in it.
  private func observe(_ panel: FloatingPanelWindow) {
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
      ) { [weak self] notification in
        let window = notification.object as? NSWindow
        MainActor.assumeIsolated {
          guard let self, let window, Self.hidesFor(window, panel: self.panel) else { return }
          self.hide()
        }
      })
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let panel = self.panel, event.window === panel,
        Self.isBareEscape(keyCode: event.keyCode, modifiers: event.modifierFlags)
      else { return event }
      self.hide()
      return nil
    }
  }

  /// Whether `window` taking the keyboard hides the panel.
  static func hidesFor(_ window: NSWindow, panel: NSWindow?) -> Bool {
    window !== panel && !(window is NSSavePanel) && window.sheetParent == nil
      && window.level == .normal
  }

  /// Escape with no modifier.
  static func isBareEscape(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
    keyCode == 53 && modifiers.isDisjoint(with: [.shift, .command, .control, .option])
  }

  /// The screen under the pointer, else the main one.
  private static func pointerScreen() -> NSScreen? {
    let pointer = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
  }

  /// Where a panel of `size` sits on `screen`: centred, a fifth of the way down, as Spotlight.
  /// - Parameters:
  ///   - size: The panel's size.
  ///   - screen: The screen, or `nil` for the origin.
  /// - Returns: The panel's bottom-left corner.
  static func origin(size: CGSize, on screen: NSScreen?) -> CGPoint {
    guard let visible = screen?.visibleFrame else { return .zero }
    return origin(size: size, in: visible)
  }

  /// Where a panel of `size` sits in `visible`, a screen's usable area.
  static func origin(size: CGSize, in visible: CGRect) -> CGPoint {
    CGPoint(
      x: (visible.midX - size.width / 2).rounded(),
      y: (visible.maxY - visible.height / 5 - size.height).rounded())
  }

}

/// The panel's window: non-activating, above other apps' windows, on every Space and over
/// full-screen apps, with a transparent title bar that only holds the Close button.
final class FloatingPanelWindow: NSPanel {
  /// Hides the panel instead of closing it.
  var onHide: (@MainActor () -> Void)?

  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered, defer: true)
    isFloatingPanel = true
    level = .floating
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isMovableByWindowBackground = true
    isReleasedWhenClosed = false
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true
    title = "New Agent"
    setAccessibilityIdentifier("floating-new-agent-panel")
  }

  override var canBecomeKey: Bool { true }

  // The Close button and Command-W hide the panel, keeping the draft.
  override func performClose(_ sender: Any?) { onHide?() }
  override func close() { onHide?() }
}
