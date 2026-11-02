import Foundation
public import OmnigentCoreFFI
import Synchronization

/// Plays a fixture stream as one attached tab: connects, sends a snapshot, then video at 15 fps
/// while visible; navigation animates progress, and a URL containing `small` switches to the
/// 640×400 stream (a format change). In control mode the user holds control from the start.
public final class FixtureRemoteBrowserDriver: RemoteBrowserDriverProtocol {
  private struct State: Sendable {
    var snapshot: RemoteBrowserSnapshot
    var tabExists: Bool
    var stream: FixtureVideoStream?
    var streamID: UInt32 = 1
    var frameIndex = 0
    var visible = true
    var running = false
    var playback: Task<Void, Never>?
    var back: [String] = []
    var forward: [String] = []
    var inputLog: [String] = []
  }

  private let state: Mutex<State>
  private let listener: any RemoteBrowserListener
  private let latency: Duration
  private static let frameInterval = Duration.milliseconds(66)

  nonisolated init(
    start: RemoteBrowserSnapshot, tabExists: Bool, latency: Duration,
    listener: any RemoteBrowserListener
  ) {
    var snapshot = start
    snapshot.connection = .connecting
    let control = start.mode == .control
    snapshot.control = RemoteBrowserControl(
      owner: control ? .user : .agent, holder: control ? .this : .nobody, userId: nil,
      handoff: nil)
    state = Mutex(State(snapshot: snapshot, tabExists: tabExists))
    self.latency = latency
    self.listener = listener
  }

  /// What the driver received, oldest first, for tests and the gallery.
  public nonisolated var inputLog: [String] { state.withLock { $0.inputLog } }

  /// Connects and starts playing.
  public nonisolated func start() {
    let snapshot = state.withLock { state -> RemoteBrowserSnapshot? in
      guard !state.running else { return nil }
      state.running = true
      return state.snapshot
    }
    guard let snapshot else { return }
    listener.onState(snapshot: snapshot)
    let task = Task.detached { [self] in await play() }
    state.withLock { $0.playback = task }
  }

  /// Stops playing for good.
  public nonisolated func stop() {
    let (task, snapshot): (Task<Void, Never>?, RemoteBrowserSnapshot) = state.withLock { state in
      state.running = false
      state.snapshot.connection = .stopped
      defer { state.playback = nil }
      return (state.playback, state.snapshot)
    }
    task?.cancel()
    listener.onState(snapshot: snapshot)
  }

  /// Records the call; the fixture never waits to reconnect.
  public nonisolated func foreground() {
    log("foreground")
  }

  /// Pauses or resumes video.
  public nonisolated func setVisible(visible: Bool) {
    state.withLock {
      $0.visible = visible
      if visible { $0.frameIndex = 0 }
    }
  }

  /// Restarts the stream at its keyframe.
  public nonisolated func requestKeyframe(reason: KeyframeReason) {
    state.withLock {
      $0.frameIndex = 0
      $0.inputLog.append("keyframe \(reason)")
    }
  }

  /// Sends the fixture thumbnail.
  public nonisolated func requestStill(kind: StillKind) {
    guard let url = Bundle.module.url(forResource: "thumbnail_320x200", withExtension: "jpg") else {
      listener.onNotice(
        message: FixtureStreamError.missingResource("thumbnail_320x200.jpg").description)
      return
    }
    do {
      listener.onStill(still: StillImage(kind: kind, ptsUs: 0, jpeg: try Data(contentsOf: url)))
    } catch {
      listener.onNotice(message: String(describing: error))
    }
  }

  /// Records clicks and changes the cursor by region.
  public nonisolated func mouse(input: MouseInput) throws {
    let cursor = input.y < 120 ? "pointer" : (input.x < 640 ? "text" : "default")
    let changed = state.withLock { state -> RemoteBrowserSnapshot? in
      if input.kind != .move {
        state.inputLog.append("mouse \(input.kind) \(Int(input.x)),\(Int(input.y))")
      }
      guard state.snapshot.cursor.keyword != cursor else { return nil }
      state.snapshot.cursor = RemoteBrowserCursor(keyword: cursor, custom: nil)
      return state.snapshot
    }
    if let changed { listener.onState(snapshot: changed) }
  }

  /// Records the key.
  public nonisolated func key(input: KeyInput) throws {
    log("key \(input.kind) \(input.key)")
  }

  /// Records the operation.
  public nonisolated func ime(input: ImeInput) throws {
    log("ime \(input.op) \(input.text ?? "")")
  }

  /// Navigates the fixture history.
  public nonisolated func nav(op command: NavOp, url: String?) throws {
    var streamError: FixtureStreamError?
    let snapshot = state.withLock { state in
      if Self.navigate(&state, command, url: url) {
        streamError = Self.switchStreamIfNeeded(&state)
      }
      return state.snapshot
    }
    listener.onState(snapshot: snapshot)
    if let streamError { listener.onNotice(message: streamError.description) }
  }

  public nonisolated func resize(viewport: RemoteViewport) throws {
    log("resize \(viewport.width)x\(viewport.height)")
  }

  /// Gives this client control.
  public nonisolated func takeControl() {
    setControl(RemoteBrowserControl(owner: .user, holder: .this, userId: nil, handoff: nil))
  }

  /// Hands control to the agent.
  public nonisolated func releaseControl() {
    setControl(RemoteBrowserControl(owner: .agent, holder: .nobody, userId: nil, handoff: nil))
  }

  /// Records the reply.
  public nonisolated func replyDialog(id: String, accept: Bool, text: String?) {
    log("dialog \(id) \(accept)")
  }

  /// Records the call.
  public nonisolated func updateSettings(update: RemoteBrowserSettingsUpdate) {
    log("settings")
  }

  private nonisolated func setControl(_ control: RemoteBrowserControl) {
    let snapshot = state.withLock {
      $0.snapshot.control = control
      return $0.snapshot
    }
    listener.onState(snapshot: snapshot)
  }

  private nonisolated func log(_ entry: String) {
    state.withLock { $0.inputLog.append(entry) }
  }

  private nonisolated func play() async {
    do {
      try await Task.sleep(for: latency)
    } catch {
      return  // Stopped while connecting.
    }
    guard connect() else { return }
    while !Task.isCancelled {
      let (frame, progressed) = state.withLock { state in Self.tick(&state) }
      if let progressed { listener.onState(snapshot: progressed) }
      if let frame { listener.onVideo(frame: frame) }
      do {
        try await Task.sleep(for: Self.frameInterval)
      } catch {
        return
      }
    }
  }

  /// Attaches, or reports the tab gone or the fixture unreadable; `true` when attached.
  private nonisolated func connect() -> Bool {
    guard state.withLock({ $0.tabExists }) else {
      let closed = state.withLock {
        $0.snapshot.connection = .closed(reason: .tabEnded(reason: .closed, detail: "tab_closed"))
        $0.running = false
        return $0.snapshot
      }
      listener.onState(snapshot: closed)
      listener.onClosed(reason: .closed)
      return false
    }
    do throws(FixtureStreamError) {
      let stream = try FixtureVideoStream(named: FixtureVideoStream.large)
      let attached = state.withLock {
        $0.stream = $0.stream ?? stream
        $0.snapshot.connection = .attached(mode: $0.snapshot.mode ?? .view)
        $0.snapshot.viewport = Self.viewport(stream)
        return $0.snapshot
      }
      listener.onState(snapshot: attached)
      return true
    } catch {
      let failed = state.withLock {
        $0.snapshot.connection = .failed(
          failure: .unrecoverable(error: .InvalidState(message: error.description)),
          message: error.description, requiresSignIn: false)
        return $0.snapshot
      }
      listener.onState(snapshot: failed)
      return false
    }
  }
}

// MARK: State transitions

extension FixtureRemoteBrowserDriver {
  /// Applies a navigation to the fixture's history; `false` when nothing changed.
  private nonisolated static func navigate(_ state: inout State, _ command: NavOp, url: String?)
    -> Bool
  {
    guard var nav = state.snapshot.nav else { return false }
    switch command {
    case .navigate:
      state.back.append(nav.url)
      state.forward.removeAll()
      nav.url = url ?? nav.url
    case .back:
      guard let previous = state.back.popLast() else { return false }
      state.forward.append(nav.url)
      nav.url = previous
    case .forward:
      guard let next = state.forward.popLast() else { return false }
      state.back.append(nav.url)
      nav.url = next
    case .reload:
      break
    case .stop:
      nav.loading = false
      nav.progress = 1
      state.snapshot.nav = nav
      return false
    }
    nav.title = FixtureRemoteBrowser.title(for: nav.url)
    nav.loading = true
    nav.progress = 0.1
    nav.canGoBack = !state.back.isEmpty
    nav.canGoForward = !state.forward.isEmpty
    state.snapshot.nav = nav
    state.inputLog.append("nav \(command) \(url ?? "")")
    return true
  }

  /// Plays the small stream for URLs containing `small`, the large one otherwise.
  private nonisolated static func switchStreamIfNeeded(_ state: inout State) -> FixtureStreamError?
  {
    let wantsSmall = state.snapshot.nav?.url.contains("small") == true
    guard wantsSmall != (state.stream?.width == 640) else { return nil }
    state.streamID += 1
    state.frameIndex = 0
    do throws(FixtureStreamError) {
      state.stream = try FixtureVideoStream(
        named: wantsSmall ? FixtureVideoStream.small : FixtureVideoStream.large,
        streamID: state.streamID, formatChanged: true)
      return nil
    } catch {
      return error
    }
  }

  /// Records the size; the fixture viewport is fixed.

  /// One frame interval: advances loading progress and picks the next frame while visible.
  private nonisolated static func tick(_ state: inout State)
    -> (VideoFrame?, RemoteBrowserSnapshot?)
  {
    var progressed: RemoteBrowserSnapshot?
    if var nav = state.snapshot.nav, nav.loading {
      nav.progress = min(1, nav.progress + 0.15)
      nav.loading = nav.progress < 1
      state.snapshot.nav = nav
      state.snapshot.viewport = state.stream.map(viewport) ?? state.snapshot.viewport
      progressed = state.snapshot
    }
    guard state.visible, let stream = state.stream, !stream.frames.isEmpty else {
      return (nil, progressed)
    }
    let frame = stream.frames[state.frameIndex % stream.frames.count]
    state.frameIndex = (state.frameIndex + 1) % stream.frames.count
    return (frame, progressed)
  }

  private nonisolated static func viewport(_ stream: FixtureVideoStream) -> RemoteViewport {
    RemoteViewport(width: UInt32(stream.width), height: UInt32(stream.height), dpr: 1)
  }
}
