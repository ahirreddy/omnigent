public import CoreGraphics
import Foundation
public import Observation
public import OmnigentBrowser
public import OmnigentCoreFFI
import os

/// One remote tab's live state over the core's driver: snapshots for the chrome, video straight
/// to the attached renderer (never through observation), and input and navigation back to the
/// driver. Listener callbacks arrive on background threads and are applied here in order.
@Observable
public final class RemoteBrowserStore {
  /// The session the tab belongs to.
  public let sessionID: String
  /// The host's tab id.
  public let tabID: String
  /// The latest snapshot.
  public private(set) var snapshot: RemoteBrowserSnapshot
  /// The latest JPEG still or thumbnail.
  public private(set) var still: StillImage?
  /// The latest notice the user can act on, shown for a few seconds. Diagnostics go to the
  /// log only.
  public private(set) var notice: String?
  /// How the remote viewport follows this view while this client holds control; saved per
  /// device.
  public var viewportMode: RemoteViewportMode {
    didSet {
      guard viewportMode != oldValue else { return }
      do {
        try RemoteViewportModeDefaults.save(viewportMode)
      } catch {
        Self.log.error("Could not save the viewport mode: \(error)")
      }
      applyViewport()
    }
  }
  /// The local pasteboard for copy and paste.
  @ObservationIgnored public var pasteboard: any RemotePasteboard = SystemPasteboard()
  /// Why the tab closed, once it did.
  public private(set) var closedReason: RemoteTabClosedReason?
  /// The URL the tab last showed, kept when it ends so it can be reopened.
  public private(set) var lastURL: String
  /// Search engine for address-field text that is not a URL.
  public var searchEngine = BrowserSearchEngine.google
  /// The local zoom in percent while the page is magnified (iOS), as the view reports it.
  public internal(set) var zoomPercent: Int?
  /// Counts ``resetZoom()`` requests; the view zooms back out when it changes.
  var zoomResets = 0
  /// The colour along the page's top edge when it is uniform, sampled from the video (iOS), for
  /// tinting the bars as Safari does with a page's theme colour.
  public internal(set) var edgeColor: RemoteEdgeColor?

  /// Receives video; the view's renderer while it is on screen.
  @ObservationIgnored public weak var renderer: RemoteVideoRenderer? {
    didSet { rendererChanged(from: oldValue) }
  }

  @ObservationIgnored private var driver: (any RemoteBrowserDriverProtocol)?
  @ObservationIgnored private var events: Task<Void, Never>?
  @ObservationIgnored private var viewSize = CGSize.zero
  @ObservationIgnored private var screenScale = 1.0
  @ObservationIgnored private var pendingViewport: Task<Void, Never>?
  @ObservationIgnored private var noticeExpiry: Task<Void, Never>?
  @ObservationIgnored var edgeSample: Task<Void, Never>?

  /// Creates a store, not yet attached.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - tabID: The tab.
  ///   - lastURL: The URL saved with the tab, shown until the host reports one.
  ///   - profile: The profile saved with the tab.
  public init(sessionID: String, tabID: String, lastURL: String = "", profile: String = "default") {
    self.sessionID = sessionID
    self.tabID = tabID
    self.lastURL = lastURL
    snapshot = .initial(url: lastURL, profile: profile)
    viewportMode = RemoteViewportModeDefaults.load()
  }

  /// The navigation state; until the host reports a URL (or after the tab ended), the last
  /// known one.
  public var navigation: RemoteBrowserNav {
    var nav =
      snapshot.nav
      ?? RemoteBrowserNav(
        url: "", title: "", loading: false, progress: 1, canGoBack: false, canGoForward: false,
        faviconUrl: nil)
    if nav.url.isEmpty { nav.url = lastURL }
    return nav
  }

  /// The profile.
  public var profile: String { snapshot.profile ?? "default" }

  /// Whether the remote tab is gone.
  public var isEnded: Bool { snapshot.isEnded }

  /// Whether this client may send input: attached for control and holding it.
  public var canSendInput: Bool {
    guard case .attached(.control) = snapshot.connection else { return false }
    return snapshot.control?.holder == .this
  }

  /// Attaches through `connector` and starts streaming.
  /// - Parameters:
  ///   - connector: The server's remote browsers.
  ///   - mode: View or control (`remoteBrowserMode(permissionLevel:)`).
  ///   - hostID: The session's host, when it has one.
  public func attach(
    using connector: any RemoteBrowserConnecting, mode: RemoteBrowserMode, hostID: String?
  ) {
    guard driver == nil else { return }
    let (stream, continuation) = AsyncStream<RemoteBrowserEvent>.makeStream()
    let driver = connector.attach(
      sessionID: sessionID, tabID: tabID, mode: mode, hostID: hostID,
      listener: RemoteBrowserEventRelay(continuation: continuation))
    self.driver = driver
    events = Task { [weak self] in
      for await event in stream {
        self?.apply(event)
      }
    }
    applyViewport()
    driver.start()
  }

  /// The protocol v1.1 features the host offers (all off until it says).
  public var capabilities: RemoteBrowserCapabilities { snapshot.capabilities }

  /// Whether the remote viewport is this device's (Set Remote Size, Fit or Mobile Size) rather
  /// than the agent's.
  public var showsOwnViewport: Bool { snapshot.viewportScope == .control }

  /// The remote view's size changed (layout, rotation, split view, the keyboard). Modes that
  /// follow the view resize the remote after the size settles for 150 ms.
  /// - Parameters:
  ///   - size: The view's size, points.
  ///   - scale: The screen's pixels per point.
  public func viewChanged(size: CGSize, scale: Double) {
    guard size != viewSize || scale != screenScale else { return }
    viewSize = size
    screenScale = scale
    guard viewportMode.followsView else { return }
    pendingViewport?.cancel()
    pendingViewport = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(150))
      } catch {
        return  // A newer size replaced this one.
      }
      self?.applyViewport()
    }
  }

  /// Tells the core which viewport this client wants while it holds control.
  private func applyViewport() {
    guard let driver else { return }
    // A mode that follows the view waits for its first layout.
    if viewportMode.followsView, viewSize.width <= 0 || viewSize.height <= 0 { return }
    let request = viewportMode.request(viewSize: viewSize, screenScale: screenScale)
    report { try driver.setViewport(request: request) }
  }

  /// Turns "Request Mobile Website" on or off in Mobile Size, reloading so the server sees the
  /// new user agent.
  /// - Parameter site: Request mobile websites.
  public func requestMobileWebsite(_ site: Bool) {
    guard case .mobile(let current) = viewportMode, current != site else { return }
    viewportMode = .mobile(site: site)
    navigate(.reload)
  }

  // MARK: Edit

  /// Copies the page's selection to the local pasteboard (the text arrives asynchronously).
  public func copy() { edit(.copy) }

  /// Cuts the page's selection to the local pasteboard.
  public func cut() { edit(.cut) }

  /// Pastes the local pasteboard's text into the page.
  public func paste() {
    guard let text = pasteboard.read(), !text.isEmpty else {
      show("The pasteboard has no text to paste.")
      return
    }
    edit(.paste, text: text)
  }

  /// Selects everything in the focused field or the page.
  public func selectAll() { edit(.selectAll) }

  /// Sends an edit command when this client holds control.
  /// - Parameters:
  ///   - command: The command.
  ///   - text: The text, for paste.
  public func edit(_ command: RemoteEditOp, text: String? = nil) {
    guard canSendInput, let driver else { return }
    report { try driver.edit(op: command, text: text) }
  }

  /// The fixture driver, when the store plays one (tests).
  var fixtureDriver: FixtureRemoteBrowserDriver? { driver as? FixtureRemoteBrowserDriver }

  /// Whether the edit commands are available: in control of a host that has them.
  public var canEdit: Bool { canSendInput && capabilities.edit }

  /// Stops streaming for good.
  public func detach() {
    driver?.stop()
    driver = nil
    events?.cancel()
    events = nil
  }

  // MARK: Input

  /// Sends a pointer event when this client holds control.
  /// - Parameter input: The event.
  public func send(_ input: MouseInput) {
    guard canSendInput, let driver else { return }
    report { try driver.mouse(input: input) }
  }

  /// Sends a key event when this client holds control.
  /// - Parameter input: The event.
  public func send(_ input: KeyInput) {
    guard canSendInput, let driver else { return }
    report { try driver.key(input: input) }
  }

  /// Sends an input-method operation when this client holds control.
  /// - Parameter input: The operation.
  public func send(_ input: ImeInput) {
    guard canSendInput, let driver else { return }
    report { try driver.ime(input: input) }
  }

  /// Sends a touch point when this client holds control.
  /// - Parameter input: The touch.
  public func send(_ input: TouchInput) {
    guard canSendInput, let driver else { return }
    report { try driver.touch(input: input) }
  }

  /// Loads what was typed in the address field: a URL, or a search.
  /// - Parameter text: The field's text.
  /// - Returns: Whether anything was loaded (empty text loads nothing).
  @discardableResult
  public func submitAddress(_ text: String) -> Bool {
    guard let input = BrowserOmnibox.interpret(text, searchEngine: searchEngine), let driver
    else { return false }
    report { try driver.nav(op: .navigate, url: input.url.absoluteString) }
    return true
  }

  /// Back, forward, reload or stop.
  /// - Parameter command: The command.
  public func navigate(_ command: NavOp) {
    guard let driver else { return }
    report { try driver.nav(op: command, url: nil) }
  }

  /// Takes control from the agent.
  public func takeControl() {
    driver?.takeControl()
  }

  /// Hands control back to the agent.
  public func releaseControl() {
    driver?.releaseControl()
  }

  /// Shows or hides the tab: hidden tabs get no video and keep navigation state.
  /// - Parameter visible: Visible.
  public func setVisible(_ visible: Bool) {
    driver?.setVisible(visible: visible)
    if visible { driver?.requestKeyframe(reason: .flush) }
  }

  /// The app or window became visible: a waiting reconnect dials now.
  public func foreground() {
    driver?.foreground()
  }

  /// Asks for a JPEG of the page.
  /// - Parameter kind: Still or thumbnail.
  public func requestStill(_ kind: StillKind) {
    driver?.requestStill(kind: kind)
  }

  private func report(_ call: () throws -> Void) {
    do {
      try call()
    } catch let error as CoreError {
      show(error.remoteBrowserMessage)
    } catch {
      show(String(describing: error))
    }
  }

  /// Shows a notice for a few seconds.
  private func show(_ message: String) {
    Self.log.notice("\(message, privacy: .public)")
    notice = message
    noticeExpiry?.cancel()
    noticeExpiry = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(5))
      } catch {
        return  // A newer notice replaced it.
      }
      self?.notice = nil
    }
  }

  // MARK: Events

  private func apply(_ event: RemoteBrowserEvent) {
    switch event {
    case .state(let snapshot):
      self.snapshot = snapshot
      if let url = snapshot.nav?.url, !url.isEmpty { lastURL = url }
    case .video(let frame):
      renderer?.enqueue(frame)
      scheduleEdgeSample()
    case .still(let still):
      self.still = still
    case .closed(let reason):
      closedReason = reason
    case .notice(let notice):
      if notice.userFacing {
        show(notice.message)
      } else {
        Self.log.debug("remote browser: \(notice.message, privacy: .public)")
      }
    case .clipboard(_, let text):
      pasteboard.write(text)
    }
  }

  private func rendererChanged(from old: RemoteVideoRenderer?) {
    guard let renderer, renderer !== old else { return }
    renderer.requestKeyframe = { [weak self] reason in
      self?.driver?.requestKeyframe(reason: reason)
    }
    driver?.requestKeyframe(reason: .flush)
  }

  private static let log = Logger(subsystem: "ai.omnigent.remote-browser", category: "store")
}

extension CoreError {
  /// The message of a remote browser error, else the error's description.
  nonisolated var remoteBrowserMessage: String {
    if case .RemoteBrowser(_, let message, _) = self { return message }
    return String(describing: self)
  }
}

/// One listener callback, carried to the main actor in order.
nonisolated enum RemoteBrowserEvent: Sendable {
  case state(RemoteBrowserSnapshot)
  case video(VideoFrame)
  case still(StillImage)
  case closed(RemoteTabClosedReason?)
  case notice(RemoteBrowserNotice)
  case clipboard(RemoteEditOp, String)
}

/// The listener the core calls on its threads; it only enqueues.
nonisolated final class RemoteBrowserEventRelay: RemoteBrowserListener {
  private let continuation: AsyncStream<RemoteBrowserEvent>.Continuation

  init(continuation: AsyncStream<RemoteBrowserEvent>.Continuation) {
    self.continuation = continuation
  }

  func onState(snapshot: RemoteBrowserSnapshot) { continuation.yield(.state(snapshot)) }
  func onVideo(frame: VideoFrame) { continuation.yield(.video(frame)) }
  func onStill(still: StillImage) { continuation.yield(.still(still)) }
  func onClosed(reason: RemoteTabClosedReason?) { continuation.yield(.closed(reason)) }
  func onNotice(notice: RemoteBrowserNotice) { continuation.yield(.notice(notice)) }
  func onClipboard(op operation: RemoteEditOp, text: String) {
    continuation.yield(.clipboard(operation, text))
  }
}
