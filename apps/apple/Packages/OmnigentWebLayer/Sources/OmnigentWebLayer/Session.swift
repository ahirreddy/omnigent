internal import AppKit
internal import Darwin
internal import Foundation
internal import OWLProtocol
public import Observation
internal import os

/// The OWL client's connection to one web host process: launches it asynchronously, performs
/// the versioned handshake, supervises it with a watchdog, and restarts it on request. Owns every
/// `Profile` and `WebView` and re-creates them in a restarted host.
@Observable
public final class Session {
  /// Start-up settings.
  public let configuration: SessionConfiguration
  /// Current lifecycle state.
  public internal(set) var state: SessionState = .idle
  /// The most recent non-fatal channel or protocol problem (unknown messages, rejected senders).
  public internal(set) var lastProtocolError: WebLayerError?
  /// Every download any view in this session started.
  public let downloads = WebDownloadList()

  @ObservationIgnored var process: HostProcess?
  @ObservationIgnored var channel: HostChannel?
  @ObservationIgnored var generation = 0
  @ObservationIgnored var token = ""
  @ObservationIgnored var requestedMode = RenderMode.remoteLayer
  /// Whether this macOS has remote layers. A test answers no.
  @ObservationIgnored var remoteLayerSupported: () -> Bool = { LayerHost.isRemoteLayerSupported }
  @ObservationIgnored var launchStart = ContinuousClock.now
  @ObservationIgnored var spawnDuration = Duration.zero
  @ObservationIgnored var helloDuration: Duration?
  @ObservationIgnored var helloInfo: HelloInfo?
  /// The host's protocol minor from Hello.
  @ObservationIgnored var hostMinor: UInt64 = 0
  @ObservationIgnored var pendingFailure: WebLayerError?
  @ObservationIgnored var timers: [Timer] = []
  @ObservationIgnored var outstandingPing: (id: UInt64, sent: ContinuousClock.Instant)?
  @ObservationIgnored var nextRequestID: UInt64 = 1
  @ObservationIgnored var replies: [UInt64: (Result<WireDecoder, WebLayerError>) -> Void] =
    [:]
  @ObservationIgnored var nextObjectID: UInt64 = 1
  @ObservationIgnored var profilesByKey: [String: Profile] = [:]
  @ObservationIgnored var profiles: [UInt64: Profile] = [:]
  @ObservationIgnored var views: [UInt64: WebView] = [:]
  @ObservationIgnored var terminationObserver: (any NSObjectProtocol)?
  /// Tests only: receives every message `post` would send, instead of the channel.
  @ObservationIgnored var outgoingTap: ((OWLMessageKind, UInt64, WireDecoder) -> Void)?

  /// Creates a session. Nothing launches until `start()`.
  public init(configuration: SessionConfiguration) {
    self.configuration = configuration
    downloads.session = self
    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.shutdown() }
    }
  }

  /// Whether Chromium is running.
  public var isReady: Bool {
    if case .ready = state { return true }
    return false
  }

  /// Whether the running host projects browser UI (prompts, downloads, popups, IME, drag and
  /// drop): protocol 1.1 or later. Older hosts deny those requests themselves.
  public var supportsBrowserUI: Bool {
    isReady && hostMinor >= UInt64(OWL_PROTOCOL_MINOR_PROMPTS)
  }

  /// Whether the running host reports browsing state (favicons, navigation history, audible
  /// state) and takes mute and hard reload: protocol 1.2 or later.
  public var supportsBrowsing: Bool {
    isReady && hostMinor >= UInt64(OWL_PROTOCOL_MINOR_BROWSING)
  }

  /// The running host, if any.
  public var hostInfo: HostInfo? {
    if case .ready(let info) = state { return info }
    return nil
  }

  /// Launches the host and returns immediately; `state` reports progress. Restarts a failed or
  /// crashed host. Does nothing while launching or ready.
  public func start() {
    switch state {
    case .launching, .ready:
      return
    case .idle, .failed, .crashed, .stopped:
      launch()
    }
  }

  /// Kills any running host and launches a new one. Profiles and views are re-created.
  public func restart() {
    if let process {
      pendingFailure = nil
      state = .stopped
      process.kill()
    }
    tearDownConnection()
    launch()
  }

  /// Asks the host to exit, waits up to `shutdownGrace`, then kills it. Blocks the caller for at
  /// most that long; called automatically when the app terminates.
  public func shutdown() {
    guard let process else {
      state = .stopped
      return
    }
    state = .stopped
    do {
      try channel?.send(.shutdown)
    } catch {
      Logger.session.error(
        "Shutdown request failed, killing the host: \(error.localizedDescription, privacy: .public)"
      )
      process.kill()
    }
    if !process.waitForExit(timeout: configuration.shutdownGrace) {
      Logger.session.error("The host did not exit within the grace period; killing it.")
      process.kill()
      if !process.waitForExit(timeout: .seconds(1)) {
        Logger.session.error("The host \(process.pid) survived SIGKILL for 1s.")
      }
    }
    tearDownConnection()
    failReplies(.notReady)
    for view in views.values {
      view.hostBecameUnavailable(nil)
    }
  }

  /// Polls until the host is ready.
  /// - Throws: The launch failure, or `.hostTimedOut` after `timeout`.
  public func waitUntilReady(timeout: Duration = .seconds(60)) async throws(WebLayerError) {
    let deadline = ContinuousClock.now + timeout
    while try !launchFinished() {
      if ContinuousClock.now >= deadline {
        throw .hostTimedOut(phase: "start-up", seconds: Double(timeout.components.seconds))
      }
      do {
        try await Task.sleep(for: .milliseconds(20))
      } catch {
        throw .notReady
      }
    }
  }

  /// Whether the host is ready, false while it launches.
  /// - Throws: The launch failure, or `.notReady` when no launch is under way.
  private func launchFinished() throws(WebLayerError) -> Bool {
    switch state {
    case .ready: true
    case .launching: false
    case .failed(let error), .crashed(let error): throw error
    case .idle, .stopped: throw .notReady
    }
  }

  /// The profile for `identifier`, created on first use. Equal identifiers share storage.
  public func profile(identifier: String, persistence: Profile.Persistence) -> Profile {
    let key = "\(persistence == .persistent ? "p" : "e"):\(identifier)"
    if let existing = profilesByKey[key] {
      return existing
    }
    let profile = Profile(
      session: self, id: allocateID(), identifier: identifier, persistence: persistence)
    profilesByKey[key] = profile
    profiles[profile.id] = profile
    if isReady {
      createInHost(profile)
    }
    return profile
  }

  /// A fresh in-memory profile isolated from every other profile, for example for one logged-out
  /// agent run. Close it when done to free its storage.
  public func makeEphemeralProfile(label: String = "agent") -> Profile {
    profile(identifier: "\(label):\(UUID().uuidString)", persistence: .ephemeral)
  }

  // MARK: Internal API for Profile and WebView

  func allocateID() -> UInt64 {
    defer { nextObjectID += 1 }
    return nextObjectID
  }

  func post(
    _ kind: OWLMessageKind, target: UInt64, _ fields: WireEncoder = WireEncoder()
  ) throws(WebLayerError) {
    if let outgoingTap {
      outgoingTap(kind, target, try WireDecoder(fields.bytes))
      return
    }
    guard isReady, let channel else { throw .notReady }
    try channel.send(kind, target: target, fields)
  }

  func request(
    _ kind: OWLMessageKind, target: UInt64, _ fields: WireEncoder = WireEncoder()
  ) async throws(WebLayerError) -> WireDecoder {
    guard isReady, let channel else { throw .notReady }
    let id = nextRequestID
    nextRequestID += 1
    let result: Result<WireDecoder, WebLayerError> = await withCheckedContinuation { continuation in
      replies[id] = { continuation.resume(returning: $0) }
      do throws(WebLayerError) {
        try channel.send(kind, request: id, target: target, fields)
      } catch {
        replies.removeValue(forKey: id)?(.failure(error))
        return
      }
      let timeout = configuration.requestTimeout
      schedule(after: timeout, generation: generation) { session in
        session.replies.removeValue(forKey: id)?(
          .failure(
            .hostTimedOut(
              phase: "request \(kind.rawValue)", seconds: Double(timeout.components.seconds))))
      }
    }
    return try result.get()
  }

  func register(_ view: WebView) {
    views[view.id] = view
    if isReady {
      view.hostReady()
    }
  }

  func unregister(_ view: WebView) {
    views.removeValue(forKey: view.id)
  }

  func remove(_ profile: Profile) {
    profiles.removeValue(forKey: profile.id)
    profilesByKey = profilesByKey.filter { $0.value !== profile }
    if isReady {
      do {
        try post(.profileDestroy, target: profile.id)
      } catch {
        Logger.session.error(
          "ProfileDestroy for \(profile.id) failed: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  /// Restarts the host if it failed or crashed; used by a view's Reload.
  func recover() {
    switch state {
    case .failed, .crashed, .stopped, .idle:
      launch()
    case .launching, .ready:
      break
    }
  }
}
