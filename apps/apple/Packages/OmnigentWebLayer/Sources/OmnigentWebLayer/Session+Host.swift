internal import AppKit
internal import Darwin
internal import Foundation
internal import OWLProtocol
internal import os

/// What the host said about itself in Hello.
struct HelloInfo {
  let pid: pid_t
  let cefVersion: String
  let chromiumVersion: String
  let protocolVersion: String
}

/// Launch, handshake, supervision and exit handling.
extension Session {
  // MARK: Launch

  func launch() {
    generation += 1
    pendingFailure = nil
    helloDuration = nil
    helloInfo = nil
    outstandingPing = nil
    launchStart = .now
    let executable = configuration.hostExecutableURL
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      state = .failed(.hostNotBundled(path: configuration.hostAppURL.path))
      return
    }
    do throws(WebLayerError) {
      try sweepPendingDeletions()
    } catch {
      // Leftover storage of a deleted profile is retried at the next launch.
      Logger.session.error(
        "Removing deleted profiles failed: \(error.localizedDescription, privacy: .public)")
      lastProtocolError = error
    }
    requestedMode = configuration.renderMode
    if requestedMode == .remoteLayer, !LayerHost.isRemoteLayerSupported {
      Logger.session.error("CALayerHost is unavailable; using the IOSurface rendering path.")
      requestedMode = .ioSurface
    }
    token = Self.randomToken()
    do throws(WebLayerError) {
      try spawn(executable: executable, generation: generation)
    } catch {
      tearDownConnection()
      process?.kill()
      process = nil
      state = .failed(error)
    }
  }

  /// Registers the channel, spawns the host and arms the start-up timeouts.
  private func spawn(executable: URL, generation current: Int) throws(WebLayerError) {
    let service = "ai.omnigent.owl.\(getpid()).\(current).\(token.prefix(8))"
    let channel = try HostChannel.listen(serviceName: service)
    channel.onEvent = { [weak self] event in self?.handle(event, generation: current) }
    channel.start()
    self.channel = channel
    let process = try HostProcess(
      executable: executable,
      arguments: [
        "--owl-service=\(service)", "--owl-token=\(token)", "--owl-parent-pid=\(getpid())",
      ])
    channel.expect(pid: process.pid)
    process.onExit = { [weak self] status, signaled in
      self?.hostExited(status: status, signaled: signaled, generation: current)
    }
    self.process = process
    spawnDuration = ContinuousClock.now - launchStart
    state = .launching
    Logger.session.info("Spawned host \(process.pid)")
    let handshake = configuration.handshakeTimeout
    schedule(after: handshake, generation: current) { session in
      if session.helloDuration == nil {
        session.abortLaunch(
          .hostTimedOut(phase: "the handshake", seconds: Double(handshake.components.seconds)))
      }
    }
    let ready = configuration.readyTimeout
    schedule(after: ready, generation: current) { session in
      if case .launching = session.state {
        session.abortLaunch(
          .hostTimedOut(phase: "starting Chromium", seconds: Double(ready.components.seconds)))
      }
    }
  }

  func abortLaunch(_ error: WebLayerError) {
    Logger.session.error("Host launch failed: \(error.localizedDescription, privacy: .public)")
    pendingFailure = error
    if let process {
      process.kill()
    } else {
      state = .failed(error)
    }
  }

  static func randomToken() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<16).map { _ in UInt8.random(in: 0...255, using: &generator).hexByte }.joined()
  }

  func schedule(
    after delay: Duration, generation: Int, repeats: Bool = false,
    _ action: @escaping @MainActor (Session) -> Void
  ) {
    let interval =
      Double(delay.components.seconds)
      + Double(delay.components.attoseconds) / 1e18
    let timer = Timer(timeInterval: interval, repeats: repeats) { [weak self] fired in
      let firedID = ObjectIdentifier(fired)
      MainActor.assumeIsolated {
        guard let self else { return }
        if !repeats {
          self.timers.removeAll { ObjectIdentifier($0) == firedID }
        }
        guard self.generation == generation else { return }
        action(self)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    timers.append(timer)
  }

  func tearDownConnection() {
    for timer in timers {
      timer.invalidate()
    }
    timers.removeAll()
    channel?.invalidate()
    channel = nil
    process = nil
    outstandingPing = nil
  }

  // MARK: Events

  func handle(_ event: HostChannel.Event, generation: Int) {
    guard generation == self.generation else { return }
    switch event {
    case .message(let message):
      handle(message)
    case .peerDied:
      // The exit handler reports the status; this only covers a host that closed its port but
      // kept running.
      schedule(after: .seconds(2), generation: generation) { session in
        if let process = session.process, process.isRunning {
          session.pendingFailure = .channelFailed("The host closed its channel.")
          process.kill()
        }
      }
    case .failure(let error):
      Logger.session.error("Channel problem: \(error.localizedDescription, privacy: .public)")
      lastProtocolError = error
    }
  }

  func handle(_ message: IncomingMessage) {
    if message.request != 0, let reply = replies.removeValue(forKey: message.request) {
      reply(.success(message.fields))
      return
    }
    switch message.kind {
    case .hello:
      handleHello(message)
    case .ready:
      handleReady(message.fields)
    case .initFailed:
      abortLaunch(.hostInitializationFailed(message.fields.string(.reason) ?? "No reason given."))
    case .pong:
      outstandingPing = nil
    case .hostError:
      handleHostError(message)
    case .popupCreated:
      adoptPopup(message)
    case .none:
      let error = WebLayerError.channelFailed("Unknown message kind \(message.kindValue).")
      Logger.session.error("\(error.localizedDescription, privacy: .public)")
      lastProtocolError = error
    default:
      if let view = views[message.target] {
        view.handle(message)
      } else {
        Logger.session.debug(
          "Message \(message.kindValue) for unknown view \(message.target) ignored after close.")
      }
    }
  }

  func handleHello(_ message: IncomingMessage) {
    guard let channel, let process else { return }
    guard let port = message.port else {
      abortLaunch(.handshakeFailed("Hello carried no host port."))
      return
    }
    do throws(WebLayerError) {
      try channel.adoptPeer(port)
    } catch {
      abortLaunch(error)
      return
    }
    let fields = message.fields
    if let rejection = validateHello(message, hostPID: process.pid) {
      do {
        try channel.send(
          .helloAck,
          WireEncoder().bool(.accepted, false).string(.reason, rejection.localizedDescription))
      } catch {
        Logger.session.error(
          "Could not send the handshake rejection: \(error.localizedDescription, privacy: .public)")
      }
      abortLaunch(rejection)
      return
    }
    helloDuration = ContinuousClock.now - launchStart
    hostMinor = fields.u64(.protocolMinor) ?? 0
    helloInfo = HelloInfo(
      pid: process.pid, cefVersion: fields.string(.cefVersion) ?? "unknown",
      chromiumVersion: fields.string(.chromiumVersion) ?? "unknown",
      protocolVersion: "\(fields.u64(.protocolMajor) ?? 0).\(fields.u64(.protocolMinor) ?? 0)")
    do throws(WebLayerError) {
      try channel.send(.helloAck, helloAck())
    } catch {
      abortLaunch(error)
    }
  }

  /// Why Hello must be rejected, or nil when it is valid.
  private func validateHello(_ message: IncomingMessage, hostPID: pid_t) -> WebLayerError? {
    let fields = message.fields
    let major = fields.u64(.protocolMajor) ?? 0
    if major != UInt64(OWL_PROTOCOL_MAJOR) || message.protocolMajor != UInt16(OWL_PROTOCOL_MAJOR) {
      return .protocolMismatch(
        host: "\(major).\(fields.u64(.protocolMinor) ?? 0)",
        client: "\(OWL_PROTOCOL_MAJOR).\(OWL_PROTOCOL_MINOR)")
    }
    if fields.string(.token) != token {
      return .handshakeFailed("The host presented the wrong token.")
    }
    if fields.u64(.hostPID) != UInt64(hostPID) {
      return .handshakeFailed("The host reported a different process ID.")
    }
    return nil
  }

  func helloAck() -> WireEncoder {
    var ack = WireEncoder()
      .bool(.accepted, true)
      .u64(.protocolMinor, UInt64(OWL_PROTOCOL_MINOR))
      .string(.rootCachePath, configuration.rootCacheURL.path)
      .u64(.remoteDebuggingPort, UInt64(max(0, configuration.remoteDebuggingPort)))
      .bool(.useMockKeychain, configuration.useMockKeychain)
      .bool(.disableSandbox, configuration.disableSandbox)
      .u64(.renderMode, requestedMode.wireValue.rawValue)
    if let locale = configuration.locale {
      ack = ack.string(.locale, locale)
    }
    if let keychain = configuration.keychainServiceName {
      ack = ack.string(.keychainService, keychain)
    }
    return ack
  }

  func handleReady(_ fields: WireDecoder) {
    guard let helloInfo, let helloDuration else {
      abortLaunch(.handshakeFailed("Ready arrived before Hello."))
      return
    }
    let info = HostInfo(
      pid: helloInfo.pid, cefVersion: helloInfo.cefVersion,
      chromiumVersion: helloInfo.chromiumVersion, protocolVersion: helloInfo.protocolVersion,
      renderMode: RenderMode(wireValue: fields.u64(.renderMode) ?? 0),
      spawnDuration: spawnDuration, helloDuration: helloDuration,
      readyDuration: ContinuousClock.now - launchStart,
      hostInitMilliseconds: fields.u64(.elapsedMilliseconds) ?? 0)
    state = .ready(info)
    Logger.session.info(
      "Host \(info.pid) ready: spawn \(info.spawnDuration), hello \(info.helloDuration), ready \(info.readyDuration), mode \(info.renderMode.rawValue)"
    )
    for profile in profiles.values.sorted(by: { $0.id < $1.id }) {
      createInHost(profile)
    }
    for view in views.values.sorted(by: { $0.id < $1.id }) {
      view.hostReady()
    }
    schedule(after: configuration.pingInterval, generation: generation, repeats: true) {
      $0.watchdogTick()
    }
  }

  func createInHost(_ profile: Profile) {
    do {
      try post(
        .profileCreate, target: profile.id,
        WireEncoder()
          .string(.storageKey, profile.storageKey)
          .bool(.persistent, profile.persistence == .persistent))
    } catch {
      Logger.session.error(
        "ProfileCreate for \(profile.id) failed: \(error.localizedDescription, privacy: .public)")
      profile.lastError = error
    }
  }

  func handleHostError(_ message: IncomingMessage) {
    let error = WebLayerError.hostError(
      code: message.fields.u64(.errorCode) ?? 0,
      message: message.fields.string(.message) ?? "No message.")
    Logger.session.error(
      "Host error for \(message.target): \(error.localizedDescription, privacy: .public)")
    if message.fields.u64(.errorCode) == OWLHostErrorCode.unknownPrompt.rawValue {
      // A reply crossed the host's withdrawal of the prompt; the view's state is fine.
      lastProtocolError = error
    } else if let view = views[message.target] {
      view.handleHostError(error, code: message.fields.u64(.errorCode) ?? 0)
    } else if let profile = profiles[message.target] {
      profile.lastError = error
    } else {
      lastProtocolError = error
    }
  }

  func watchdogTick() {
    guard isReady, let channel else { return }
    if let outstandingPing {
      let waited = ContinuousClock.now - outstandingPing.sent
      if waited > configuration.hangTimeout {
        let seconds = Double(waited.components.seconds)
        Logger.session.error("Host unresponsive for \(seconds)s; killing it.")
        pendingFailure = .hostUnresponsive(seconds: seconds)
        process?.kill()
      }
      return
    }
    let id = nextRequestID
    nextRequestID += 1
    outstandingPing = (id, .now)
    do {
      try channel.send(.ping, request: id)
    } catch {
      Logger.session.error("Ping failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  func hostExited(status: Int32, signaled: Bool, generation: Int) {
    guard generation == self.generation else { return }
    let reason = signaled ? "killed by signal \(status)" : "exited"
    let error = pendingFailure ?? .hostExited(status: status, reason: reason)
    pendingFailure = nil
    tearDownConnection()
    switch state {
    case .stopped:
      Logger.session.info("Host \(reason) after shutdown (status \(status)).")
      return
    case .launching, .idle, .failed:
      state = .failed(error)
    case .ready, .crashed:
      state = .crashed(error)
    }
    Logger.session.error(
      "Host \(reason) unexpectedly (status \(status)): \(error.localizedDescription, privacy: .public)"
    )
    failReplies(error)
    for view in views.values {
      view.hostBecameUnavailable(error)
    }
  }

  func failReplies(_ error: WebLayerError) {
    let pending = replies
    replies.removeAll()
    for reply in pending.values {
      reply(.failure(error))
    }
  }
}
