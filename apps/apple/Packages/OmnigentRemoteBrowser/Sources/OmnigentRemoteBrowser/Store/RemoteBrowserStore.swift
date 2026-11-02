import Foundation
public import Observation
public import OmnigentBrowser
public import OmnigentCoreFFI

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
  /// The latest notice from the core, or a rejected input.
  public private(set) var notice: String?
  /// Why the tab closed, once it did.
  public private(set) var closedReason: RemoteTabClosedReason?
  /// The URL the tab last showed, kept when it ends so it can be reopened.
  public private(set) var lastURL: String
  /// Search engine for address-field text that is not a URL.
  public var searchEngine = BrowserSearchEngine.google

  /// Receives video; the view's renderer while it is on screen.
  @ObservationIgnored public weak var renderer: RemoteVideoRenderer? {
    didSet { rendererChanged(from: oldValue) }
  }

  @ObservationIgnored private var driver: (any RemoteBrowserDriverProtocol)?
  @ObservationIgnored private var events: Task<Void, Never>?

  /// Creates a store, not yet attached.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - tabID: The tab.
  ///   - lastURL: The URL saved with the tab, shown until the host reports one.
  ///   - profile: The profile saved with the tab.
  public init(sessionID: String, tabID: String, lastURL: String = "", profile: String = "default")
  {
    self.sessionID = sessionID
    self.tabID = tabID
    self.lastURL = lastURL
    snapshot = .initial(url: lastURL, profile: profile)
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
    driver.start()
  }

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
      notice = error.remoteBrowserMessage
    } catch {
      notice = String(describing: error)
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
    case .still(let still):
      self.still = still
    case .closed(let reason):
      closedReason = reason
    case .notice(let message):
      notice = message
    }
  }

  private func rendererChanged(from old: RemoteVideoRenderer?) {
    guard let renderer, renderer !== old else { return }
    renderer.requestKeyframe = { [weak self] reason in
      self?.driver?.requestKeyframe(reason: reason)
    }
    driver?.requestKeyframe(reason: .flush)
  }
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
  case notice(String)
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
  func onNotice(message: String) { continuation.yield(.notice(message)) }
}
