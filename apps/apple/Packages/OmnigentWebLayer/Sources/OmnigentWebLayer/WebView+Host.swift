internal import Foundation
internal import IOSurface
internal import OWLProtocol
internal import os

/// Session callbacks and host events.
extension WebView {
  func hostReady() {
    guard status != .closed else { return }
    status = .creating
    createdAt = .now
    sawFirstFrame = false
    let target = url ?? requestedURL
    navigationPendingCreation = false
    var fields = geometryFields()
      .u64(.profileID, profile.id)
      .bool(.visible, isVisible)
      .u64(.popupPolicy, popupPolicy.wire.rawValue)
    if let navigationRules { fields = fields.string(.rules, navigationRules.json) }
    if let target { fields = fields.string(.URL, target.absoluteString) }
    do {
      try session.post(.viewCreate, target: id, fields)
    } catch {
      status = .unavailable(error)
      lastError = error
    }
    changed()
  }

  /// `error` is nil after a requested shutdown.
  func hostBecameUnavailable(_ error: WebLayerError?) {
    guard status != .closed else { return }
    layerHost.reset()
    isLoading = false
    finishFind(FindResult(matchCount: 0, activeMatch: nil))
    withdrawPrompts(reason: "The Chromium web host stopped.")
    if let error {
      status = .unavailable(error)
      lastError = error
    } else {
      status = .waitingForHost
    }
    changed()
  }

  func handleHostError(_ error: WebLayerError, code: UInt64) {
    lastError = error
    if code == OWLHostErrorCode.viewCreateFailed.rawValue
      || code == OWLHostErrorCode.unknownProfile.rawValue
    {
      status = .unavailable(error)
    }
    changed()
  }

  func handle(_ message: IncomingMessage) {
    guard let kind = message.kind else {
      Logger.view.error("View \(self.id) got unknown message \(message.kindValue).")
      return
    }
    if handleRendering(kind, message) {
      return
    }
    if handleNavigation(kind, message.fields) || handlePageEvent(kind, message.fields)
      || handleBrowserUI(kind, message.fields) || handleBrowsing(kind, message.fields)
      || handleSignIn(kind, message.fields)
    {
      changed()
      return
    }
    Logger.view.error("View \(self.id) got unexpected message \(message.kindValue).")
  }

  private func handleNavigation(_ kind: OWLMessageKind, _ fields: WireDecoder) -> Bool {
    switch kind {
    case .viewCreated:
      viewCreated()
    case .urlChanged:
      url = fields.string(.URL).flatMap(URL.init(string:))
    case .titleChanged:
      title = fields.string(.title) ?? ""
    case .loadingState:
      let loading = fields.bool(.isLoading)
      if loading, !isLoading { lastError = nil }
      isLoading = loading
      canGoBack = fields.bool(.canGoBack)
      canGoForward = fields.bool(.canGoForward)
    case .loadProgress:
      estimatedProgress = fields.double(.progress) ?? 0
    case .loadError:
      loadFailed(fields)
    case .viewClosed:
      if status != .closed {
        status = .closed
        session.unregister(self)
      }
    default:
      return false
    }
    return true
  }

  private func loadFailed(_ fields: WireDecoder) {
    let failedURL = fields.string(.URL).flatMap(URL.init(string:))
    let code = Int(fields.i64(.errorCode) ?? 0)
    if code == Self.netErrorAborted, case .navigationBlocked = lastError {
      return  // The rules aborted it; keep the reason rather than a plain cancellation.
    }
    lastError =
      code == Self.netErrorAborted
      ? .navigationCancelled(url: failedURL)
      : .navigationFailed(url: failedURL, code: code, message: fields.string(.text) ?? "")
  }

  private func handlePageEvent(_ kind: OWLMessageKind, _ fields: WireDecoder) -> Bool {
    switch kind {
    case .rendererGone:
      let termination = RendererTermination(
        status: fields.i64(.status) ?? 0, code: fields.i64(.errorCode) ?? 0,
        hostMessage: fields.string(.message) ?? "")
      // The raw numbers go to the log, where a crash report can be matched to them.
      Logger.view.error(
        "View \(self.id)'s renderer ended: status \(termination.status), code \(termination.code).")
      let detail = termination.summary
      lastError = .rendererTerminated(detail)
      onEvent?(.rendererTerminated(detail))
    case .downloadBlocked:
      let blocked = fields.string(.URL).flatMap(URL.init(string:))
      lastError = .downloadBlocked(url: blocked)
      onEvent?(.downloadBlocked(blocked))
    case .featureBlocked:
      let feature = fields.string(.feature) ?? "A browser feature"
      let detail = fields.string(.message) ?? ""
      lastError = .featureBlocked(feature: feature, detail: detail)
      onEvent?(.featureBlocked(feature: feature, detail: detail))
    case .cursorChanged:
      cursor = WebCursor(wire: fields.u64(.cursor) ?? 0)
    case .layerContext:
      attachRemoteContext(fields)
    default:
      return false
    }
    return true
  }

  /// Frequent messages that change no observable state.
  private func handleRendering(_ kind: OWLMessageKind, _ message: IncomingMessage) -> Bool {
    let fields = message.fields
    switch kind {
    case .frame:
      presentFrame(message)
    case .presented:
      recordPresented(fields)
    case .popupVisibility:
      if let released = layerHost.setPopupVisible(fields.bool(.visible)) {
        acknowledge(released)
      }
    case .findResult:
      if fields.bool(.finalUpdate) {
        let count = Int(fields.i64(.count) ?? 0)
        let active = Int(fields.i64(.activeMatch) ?? 0)
        finishFind(FindResult(matchCount: count, activeMatch: count > 0 ? active : nil))
      }
    case .keyUnhandled:
      renderer.handleUnhandledKey(fields)
    default:
      return false
    }
    return true
  }

  private func viewCreated() {
    status = .live
    // Geometry, visibility and focus may have changed while the browser was being created.
    sendIfLive(.viewResize, geometryFields())
    sendIfLive(.viewVisibility, WireEncoder().bool(.visible, isVisible))
    if isFocused { sendIfLive(.viewFocus, WireEncoder().bool(.focused, true)) }
    if zoomLevel != 0 { sendIfLive(.setZoom, WireEncoder().double(.zoomLevel, zoomLevel)) }
    if isAudioMuted { sendMuted() }
    sendPolicies()
    if navigationPendingCreation, let requestedURL {
      navigationPendingCreation = false
      send(.navigate, WireEncoder().string(.URL, requestedURL.absoluteString))
    }
  }

  private func attachRemoteContext(_ fields: WireDecoder) {
    guard let contextID = fields.u64(.contextID) else {
      lastError = .renderingUnavailable("LayerContext carried no context ID.")
      return
    }
    do throws(WebLayerError) {
      try layerHost.attachRemoteContext(UInt32(truncatingIfNeeded: contextID))
    } catch {
      lastError = error
    }
  }

  private func presentFrame(_ message: IncomingMessage) {
    let fields = message.fields
    guard let port = message.port, let surfaceID = fields.u64(.surfaceIndex),
      let width = fields.u64(.pixelWidth), let height = fields.u64(.pixelHeight)
    else {
      lastError = .renderingUnavailable("A frame arrived without its surface.")
      changed()
      return
    }
    guard let surface = IOSurfaceLookupFromMachPort(port.name) else {
      lastError = .renderingUnavailable("The frame's IOSurface port could not be opened.")
      changed()
      return
    }
    let frame = SurfaceFrame(
      surface: surface, surfaceID: UInt32(truncatingIfNeeded: surfaceID),
      layer: OWLLayer(rawValue: fields.u64(.layer) ?? 0) ?? .page,
      pixelSize: CGSize(width: Double(width), height: Double(height)),
      scale: fields.double(.scale) ?? scale,
      popupOrigin: CGPoint(x: fields.double(.X) ?? 0, y: fields.double(.Y) ?? 0),
      popupVisible: fields.bool(.visible))
    for released in layerHost.present(frame) {
      acknowledge(released)
    }
    let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    let paint = fields.u64(.hostTimestampNanos) ?? now
    statistics.framesDropped = fields.u64(.droppedFrames) ?? statistics.framesDropped
    statistics.record(
      latency: Double(now &- paint) / 1000,
      copy: Double(fields.u64(.hostBlitNanos) ?? 0) / 1000)
    noteFirstFrame()
  }

  private func recordPresented(_ fields: WireDecoder) {
    let paint = fields.u64(.hostTimestampNanos) ?? 0
    let presented = fields.u64(.presentedNanos) ?? paint
    statistics.framesDropped = fields.u64(.droppedFrames) ?? statistics.framesDropped
    statistics.record(
      latency: Double(presented &- paint) / 1000,
      copy: Double(fields.u64(.hostBlitNanos) ?? 0) / 1000)
    noteFirstFrame()
  }

  private func noteFirstFrame() {
    guard !sawFirstFrame else { return }
    sawFirstFrame = true
    onEvent?(.firstFramePresented(ContinuousClock.now - createdAt))
  }

  private func acknowledge(_ surfaceID: UInt32) {
    sendIfLive(.frameAck, WireEncoder().u64(.surfaceIndex, UInt64(surfaceID)))
  }
}
