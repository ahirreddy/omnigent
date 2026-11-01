public import AppKit
public import Foundation
internal import OWLProtocol
public import Observation
internal import os

/// One browsing context in the host: embed (through `LayerHost`), navigate, zoom, evaluate,
/// capture, and forward input (through `WebContentRenderer`).
@Observable
public final class WebView {
  /// Lifecycle of the view's browser in the host.
  public enum Status: Sendable, Hashable {
    /// Waiting for the host to be ready.
    case waitingForHost
    /// The host is creating the browser.
    case creating
    /// The browser exists and renders.
    case live
    /// The host is gone or could not create the browser. `reload()` recovers when possible.
    case unavailable(WebLayerError)
    /// Closed for good.
    case closed
  }

  /// Session-unique ID used on the wire.
  public let id: UInt64
  /// The profile whose storage the view uses.
  public let profile: Profile
  /// Lifecycle status.
  public internal(set) var status = Status.waitingForHost
  /// Current main-frame URL.
  public internal(set) var url: URL?
  /// Current document title.
  public internal(set) var title = ""
  /// Whether a main-frame load is in flight.
  public internal(set) var isLoading = false
  /// Load progress in `0...1`.
  public internal(set) var estimatedProgress: Double = 0
  /// Whether history has a previous entry.
  public internal(set) var canGoBack = false
  /// Whether history has a next entry.
  public internal(set) var canGoForward = false
  /// Most recent failure, cleared when a new navigation starts.
  public internal(set) var lastError: WebLayerError?
  /// Cursor the page wants.
  public internal(set) var cursor = WebCursor.pointer
  /// Zoom level; 0 is 100%, each step is 20%.
  public internal(set) var zoomLevel: Double = 0
  /// Prompts waiting for an answer, oldest first (protocol 1.1).
  public internal(set) var pendingPrompts: [WebPrompt] = []
  /// Which page-opened windows are allowed. Applied in the host before the first navigation.
  public var popupPolicy = WebPopupPolicy.requireUserGesture {
    didSet { sendPolicies() }
  }
  /// Rules every navigation in this view must pass, enforced in the host (redirects and
  /// page-initiated navigations included). Popups inherit them. Nil allows everything.
  public var navigationRules: WebNavigationRules? {
    didSet { sendPolicies() }
  }
  /// The view that opened this one, for popups.
  public internal(set) weak var opener: WebView?
  /// Keeps the page rendering and taking input while no window shows it, for agent views that
  /// are never on screen. Hidden Chromium widgets drop input, so such views report themselves
  /// visible to the host regardless of where their hosting view is.
  public var rendersOffscreen = false {
    didSet {
      if rendersOffscreen { setVisible(true) }
    }
  }

  /// Input forwarding for the user and for agents.
  @ObservationIgnored public private(set) lazy var renderer = WebContentRenderer(webView: self)
  /// The layers to embed.
  @ObservationIgnored public let layerHost = LayerHost()
  /// Called for events that are not state, such as blocked features.
  @ObservationIgnored public var onEvent: ((WebViewEvent) -> Void)?
  /// Receives dialogs, permission prompts, file choosers, downloads, popups and the rest of the
  /// browser UI a page asks for. Without one, those requests are denied (protocol 1.0 behavior).
  @ObservationIgnored public weak var uiDelegate: (any WebViewUIDelegate)?
  /// IME: the composition's character rects in view points, as the host last reported them.
  @ObservationIgnored public internal(set) var compositionCharacterRects: [CGRect] = []
  /// The page's selected text, as the host last reported it.
  @ObservationIgnored public internal(set) var selectedText = ""
  /// The selection's range in the focused element, in UTF-16 units.
  @ObservationIgnored public internal(set) var selectedRange = NSRange(location: 0, length: 0)
  /// The operation the page accepts for the drag over it.
  @ObservationIgnored public internal(set) var dragOperation: WebDragOperations = []
  /// Called after any observable property changes. Lets adapters mirror state without
  /// observation tracking.
  @ObservationIgnored public var onStateChange: (() -> Void)?
  /// Frame counters.
  @ObservationIgnored public internal(set) var statistics = FrameStatistics()

  @ObservationIgnored var requestedURL: URL?
  @ObservationIgnored var navigationPendingCreation = false
  @ObservationIgnored var size = CGSize(width: 800, height: 600)
  @ObservationIgnored var scale: Double = 2
  @ObservationIgnored var screenOrigin = CGPoint.zero
  @ObservationIgnored var isVisible = true
  @ObservationIgnored var isFocused = false
  @ObservationIgnored var createdAt = ContinuousClock.now
  @ObservationIgnored var sawFirstFrame = false
  @ObservationIgnored var pendingFind: CheckedContinuation<FindResult, Never>?
  /// Set by `WebSurfaceView` to start a native drag the page began.
  @ObservationIgnored var onStartDrag: ((WebDragStart) -> Void)?

  /// net::ERR_ABORTED, reported when a navigation is stopped or superseded.
  static let netErrorAborted = -3

  var session: Session { profile.session }

  init(profile: Profile, id: UInt64, initialURL: URL?) {
    self.profile = profile
    self.id = id
    requestedURL = initialURL
    url = initialURL
  }

  // MARK: Navigation

  /// Starts a main-frame navigation, or remembers it until the view exists.
  public func load(_ url: URL) {
    guard status != .closed else { return }
    requestedURL = url
    lastError = nil
    if status == .live {
      send(.navigate, WireEncoder().string(.URL, url.absoluteString))
    } else {
      navigationPendingCreation = status == .creating
    }
    changed()
  }

  /// Navigates back.
  public func goBack() { sendIfLive(.goBack) }
  /// Navigates forward.
  public func goForward() { sendIfLive(.goForward) }
  /// Stops the current load.
  public func stopLoading() { sendIfLive(.stop) }

  /// Reloads the page. When the host has exited, restarts it and re-creates the view at its last
  /// URL.
  public func reload() {
    switch status {
    case .live:
      send(.reload)
    case .unavailable:
      status = .waitingForHost
      lastError = nil
      changed()
      session.recover()
    case .waitingForHost, .creating, .closed:
      break
    }
  }

  /// Sets the zoom level (0 is 100%).
  public func setZoomLevel(_ level: Double) {
    zoomLevel = level
    sendIfLive(.setZoom, WireEncoder().double(.zoomLevel, level))
    changed()
  }

  // MARK: Agent-facing calls

  /// Evaluates `script` in the main frame and returns its completion value. Promises are not
  /// awaited.
  public func evaluateJavaScript(_ script: String) async throws(WebLayerError) -> WebScriptValue {
    let reply = try await liveRequest(.evaluate, WireEncoder().string(.script, script))
    let json = reply.string(.JSON) ?? ""
    guard reply.bool(.success) else {
      throw .devToolsFailed(
        method: "Runtime.evaluate", message: DevToolsJSON.failureMessage(json))
    }
    return try WebScriptValue.fromEvaluateResult(json: json)
  }

  /// Captures what the user sees, including an open popup such as a `<select>` menu, as PNG.
  public func snapshotPNG() async throws(WebLayerError) -> Data {
    let reply = try await liveRequest(.snapshot)
    guard reply.bool(.success), let png = reply.data(.PNG) else {
      throw .snapshotFailed(reply.string(.message) ?? "The host returned no image.")
    }
    return png
  }

  /// Runs a Chrome DevTools Protocol method and returns its JSON result.
  public func callDevToolsMethod(_ method: String, paramsJSON: String? = nil)
    async throws(WebLayerError) -> String
  {
    var fields = WireEncoder().string(.method, method)
    if let paramsJSON { fields = fields.string(.JSON, paramsJSON) }
    let reply = try await liveRequest(.devToolsMethod, fields)
    let json = reply.string(.JSON) ?? ""
    guard reply.bool(.success) else {
      throw .devToolsFailed(method: method, message: DevToolsJSON.failureMessage(json))
    }
    return json
  }

  /// Highlights the next match for `text`.
  public func find(_ text: String, forward: Bool = true, caseSensitive: Bool = false)
    async throws(WebLayerError) -> FindResult
  {
    guard status == .live else { throw status == .closed ? .viewClosed : .notReady }
    finishFind(FindResult(matchCount: 0, activeMatch: nil))
    try session.post(
      .find, target: id,
      WireEncoder().string(.text, text).bool(.forward, forward).bool(.matchCase, caseSensitive)
        .bool(.findNext, true))
    return await withCheckedContinuation { pendingFind = $0 }
  }

  /// Clears find highlights.
  public func stopFinding() {
    finishFind(FindResult(matchCount: 0, activeMatch: nil))
    sendIfLive(.stopFind)
  }

  /// Opens Chromium DevTools for this view in a host window.
  public func showDevTools() throws(WebLayerError) {
    guard status == .live else { throw .notReady }
    try session.post(.showDevTools, target: id)
  }

  /// Closes the view and its browser. Idempotent.
  public func close() {
    guard status != .closed else { return }
    let wasLive = status == .live || status == .creating
    status = .closed
    isLoading = false
    finishFind(FindResult(matchCount: 0, activeMatch: nil))
    withdrawPrompts(reason: "The view was closed.")
    layerHost.reset()
    if wasLive {
      do {
        try session.post(.viewClose, target: id)
      } catch {
        Logger.view.error(
          "ViewClose for \(self.id) failed: \(error.localizedDescription, privacy: .public)")
      }
    }
    session.unregister(self)
    changed()
  }

  // MARK: Geometry and focus, from the hosting view

  /// Reports the view's size in points, backing scale and screen origin (top-left).
  public func updateGeometry(size: CGSize, scale: Double, screenOrigin: CGPoint) {
    guard size != self.size || scale != self.scale || screenOrigin != self.screenOrigin else {
      return
    }
    self.size = size
    self.scale = scale
    self.screenOrigin = screenOrigin
    sendIfLive(.viewResize, geometryFields())
  }

  /// Reports whether the view is on screen; hidden views stop rendering.
  public func setVisible(_ visible: Bool) {
    let visible = visible || rendersOffscreen
    guard visible != isVisible else { return }
    isVisible = visible
    sendIfLive(.viewVisibility, WireEncoder().bool(.visible, visible))
  }

  /// Reports keyboard focus.
  public func setFocused(_ focused: Bool) {
    guard focused != isFocused else { return }
    isFocused = focused
    sendIfLive(.viewFocus, WireEncoder().bool(.focused, focused))
  }

  // MARK: Helpers

  func geometryFields() -> WireEncoder {
    WireEncoder()
      .double(.width, max(1, size.width))
      .double(.height, max(1, size.height))
      .double(.scale, scale)
      .double(.screenX, screenOrigin.x)
      .double(.screenY, screenOrigin.y)
  }

  func liveRequest(_ kind: OWLMessageKind, _ fields: WireEncoder = WireEncoder())
    async throws(WebLayerError) -> WireDecoder
  {
    switch status {
    case .live:
      return try await session.request(kind, target: id, fields)
    case .closed:
      throw .viewClosed
    case .unavailable(let error):
      throw error
    case .waitingForHost, .creating:
      throw .notReady
    }
  }

  func sendIfLive(_ kind: OWLMessageKind, _ fields: WireEncoder = WireEncoder()) {
    guard status == .live else { return }
    send(kind, fields)
  }

  func send(_ kind: OWLMessageKind, _ fields: WireEncoder = WireEncoder()) {
    do {
      try session.post(kind, target: id, fields)
    } catch {
      Logger.view.error(
        "Message \(kind.rawValue) for view \(self.id) failed: \(error.localizedDescription, privacy: .public)"
      )
      lastError = error
      changed()
    }
  }

  func finishFind(_ result: FindResult) {
    pendingFind?.resume(returning: result)
    pendingFind = nil
  }

  func changed() {
    onStateChange?()
  }
}
