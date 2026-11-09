public import AppKit
internal import OmnigentInput
public import SwiftUI

/// Embeds a `WebView`: shows its layers, forwards user input through its renderer, reports
/// geometry, visibility and focus, and overlays start-up progress or a recoverable error.
public final class WebLayerView: NSView {
  /// The view being displayed.
  public let webView: WebView
  private let surface: WebSurfaceView
  private let overlay: NSHostingView<WebViewStatusOverlay>

  /// Creates the view.
  public init(webView: WebView) {
    self.webView = webView
    surface = WebSurfaceView(webView: webView)
    overlay = NSHostingView(rootView: WebViewStatusOverlay(webView: webView))
    super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    addSubview(surface)
    addSubview(overlay)
    observeStatus()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  override public func layout() {
    super.layout()
    surface.frame = bounds
    overlay.frame = bounds
  }

  /// Gives keyboard focus to the page.
  public func focusPage() {
    hostWindow?.makeFirstResponder(surface)
  }

  private func observeStatus() {
    overlay.isHidden = webView.status == .live || webView.status == .closed
    withObservationTracking {
      _ = webView.status
    } onChange: { [weak self] in
      Task { @MainActor in self?.observeStatus() }
    }
  }
}

/// The layer-hosting surface that receives input. IME composition is in
/// `WebSurfaceView+TextInput.swift`, drag and drop in `WebSurfaceView+Drag.swift`.
class WebSurfaceView: NSView {
  let webView: WebView
  private var redispatching = false
  private var trackingArea: NSTrackingArea?
  private var windowObservers: [any NSObjectProtocol] = []
  /// IME state between `setMarkedText`, `insertText` and the key-down that caused them.
  let textComposer = TextInputComposer()
  /// The page-started drag in flight, if any.
  var pageDrag: WebDragStart?
  /// The most recent mouse-down, which a page-started drag needs to begin.
  var lastMouseDown: NSEvent?

  init(webView: WebView) {
    self.webView = webView
    super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    layer = CALayer()
    wantsLayer = true
    layer?.addSublayer(webView.layerHost.rootLayer)
    textComposer.sink = self
    webView.renderer.onUnhandledKeyEvent = { [weak self] event in self?.redispatch(event) }
    webView.onStartDrag = { [weak self] start in self?.beginPageDrag(start) }
    registerForDraggedTypes(Self.acceptedDragTypes)
    observeCursor()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func becomeFirstResponder() -> Bool {
    webView.setFocused(true)
    return true
  }

  override func resignFirstResponder() -> Bool {
    webView.setFocused(false)
    return true
  }

  // MARK: Geometry

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    reportGeometry()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    reportGeometry()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    for observer in windowObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    windowObservers.removeAll()
    if let window = hostWindow {
      let center = NotificationCenter.default
      for name in [NSWindow.didMoveNotification, NSWindow.didChangeOcclusionStateNotification] {
        windowObservers.append(
          center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportGeometry() }
          })
      }
    }
    reportGeometry()
  }

  override func viewDidHide() {
    super.viewDidHide()
    reportGeometry()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    reportGeometry()
  }

  private func reportGeometry() {
    webView.layerHost.layout(bounds: bounds)
    guard let window = hostWindow else {
      webView.setVisible(false)
      return
    }
    let screenRect = window.convertToScreen(convert(bounds, to: nil))
    let primaryHeight = NSScreen.screens.first?.frame.maxY ?? screenRect.maxY
    webView.updateGeometry(
      size: bounds.size, scale: window.backingScaleFactor,
      screenOrigin: CGPoint(x: screenRect.minX, y: primaryHeight - screenRect.maxY))
    webView.setVisible(window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor)
  }

  // MARK: Mouse

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    trackingArea = area
  }

  private func forwardMouse(_ event: NSEvent) {
    webView.renderer.forwardMouseEvent(event, location: convert(event.locationInWindow, from: nil))
  }

  override func mouseDown(with event: NSEvent) {
    hostWindow?.makeFirstResponder(self)
    lastMouseDown = event
    forwardMouse(event)
  }

  override func mouseUp(with event: NSEvent) { forwardMouse(event) }
  override func mouseDragged(with event: NSEvent) { forwardMouse(event) }
  override func mouseMoved(with event: NSEvent) { forwardMouse(event) }
  override func mouseEntered(with event: NSEvent) { forwardMouse(event) }
  override func mouseExited(with event: NSEvent) { forwardMouse(event) }

  override func rightMouseDown(with event: NSEvent) {
    hostWindow?.makeFirstResponder(self)
    forwardMouse(event)
  }

  override func rightMouseUp(with event: NSEvent) { forwardMouse(event) }
  override func rightMouseDragged(with event: NSEvent) { forwardMouse(event) }
  override func otherMouseDown(with event: NSEvent) { forwardMouse(event) }
  override func otherMouseUp(with event: NSEvent) { forwardMouse(event) }
  override func otherMouseDragged(with event: NSEvent) { forwardMouse(event) }
  override func scrollWheel(with event: NSEvent) { forwardMouse(event) }

  // MARK: Keyboard

  override func keyDown(with event: NSEvent) {
    guard !redispatching else {
      super.keyDown(with: event)
      return
    }
    // Command chords never compose text; everything else goes through the input context so
    // input methods and dead keys work (protocol 1.1 hosts).
    guard webView.session.supportsBrowserUI, !event.modifierFlags.contains(.command) else {
      webView.renderer.forwardKeyEvent(event)
      return
    }
    textComposer.keyDown(event, context: inputContext)
  }

  override func keyUp(with event: NSEvent) {
    guard !redispatching else {
      super.keyUp(with: event)
      return
    }
    webView.renderer.forwardKeyEvent(event)
  }

  override func flagsChanged(with event: NSEvent) {
    webView.renderer.forwardKeyEvent(event)
  }

  /// The page gets the first chance at key equivalents, as in Chromium; ones it does not handle
  /// come back through `redispatch`.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard !redispatching, event.type == .keyDown, hostWindow?.firstResponder === self,
      webView.status == .live
    else {
      return super.performKeyEquivalent(with: event)
    }
    webView.renderer.forwardKeyEvent(event)
    return true
  }

  private func redispatch(_ event: NSEvent) {
    redispatching = true
    defer { redispatching = false }
    // The window first, as AppKit orders key equivalents: shortcuts of SwiftUI controls in the
    // window (a browser toolbar's Find, Zoom) live in its view hierarchy, not the main menu.
    if event.modifierFlags.contains(.command), hostWindow?.performKeyEquivalent(with: event) == true
    {
      return
    }
    if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
      return
    }
    unsafe nextResponder?.keyDown(with: event)
  }

  // MARK: Cursor

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: Self.nsCursor(webView.cursor))
  }

  private func observeCursor() {
    withObservationTracking {
      _ = webView.cursor
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.hostWindow?.invalidateCursorRects(for: self)
        if let window = self.hostWindow {
          self.updateCursor(
            pointerAt: self.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        self.observeCursor()
      }
    }
  }

  /// Shows the page's cursor at once when the pointer, at `point`, is over the view.
  func updateCursor(pointerAt point: CGPoint) {
    if bounds.contains(point) {
      Self.nsCursor(webView.cursor).set()
    }
  }

  private static func nsCursor(_ cursor: WebCursor) -> NSCursor {
    switch cursor {
    case .pointer, .wait, .none: .arrow
    case .hand: .pointingHand
    case .iBeam: .iBeam
    case .crosshair: .crosshair
    case .help: .arrow
    case .resizeLeftRight: .resizeLeftRight
    case .resizeUpDown: .resizeUpDown
    case .notAllowed: .operationNotAllowed
    case .grab: .openHand
    case .grabbing: .closedHand
    }
  }
}

extension NSView {
  /// `NSView.window` is `unowned(unsafe)`; AppKit keeps it valid while the view is in a window,
  /// and these views only read it on the main thread during their own callbacks.
  var hostWindow: NSWindow? { unsafe window }
}

/// Start-up progress, or the error with a Reload button.
struct WebViewStatusOverlay: View {
  let webView: WebView

  var body: some View {
    switch webView.status {
    case .waitingForHost, .creating:
      ProgressView {
        Text("Starting Chromium…")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.background)
      .accessibilityIdentifier("weblayer.starting")
    case .unavailable(let error):
      ContentUnavailableView {
        Label("This page stopped", systemImage: "exclamationmark.triangle")
      } description: {
        Text(error.localizedDescription)
          .textSelection(.enabled)
      } actions: {
        Button("Reload") { webView.reload() }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("weblayer.reload")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.background)
      .accessibilityIdentifier("weblayer.unavailable")
    case .live, .closed:
      Color.clear
    }
  }
}

/// SwiftUI wrapper for `WebLayerView`.
public struct WebLayerContent: NSViewRepresentable {
  private let webView: WebView

  /// Creates the wrapper.
  public init(webView: WebView) {
    self.webView = webView
  }

  /// Creates the AppKit view.
  public func makeNSView(context: Context) -> WebLayerView {
    WebLayerView(webView: webView)
  }

  /// Nothing to update; the view observes its `WebView`.
  public func updateNSView(_ nsView: WebLayerView, context: Context) {}
}
