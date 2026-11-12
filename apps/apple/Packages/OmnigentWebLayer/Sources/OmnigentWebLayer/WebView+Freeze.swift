internal import Foundation
internal import OWLProtocol
internal import os

/// Freeze diagnostics for one view: what the client sent and got back, and the lines it writes.
/// See DESIGN.md, "Freeze diagnostics".
extension WebView {
  /// Counts an input aimed at the page, whether or not the view could send it.
  func noteInput(_ input: OWLInputClass) {
    freeze.noteInput(input, sent: status == .live, now: session.uptimeNanos())
  }

  /// A frame reached the screen (remote layer) or this process (IOSurface).
  func noteFrame() {
    freeze.noteFrame(now: session.uptimeNanos())
  }

  /// One tick of the session's freeze timer.
  func freezeTick(now: UInt64) {
    switch freeze.tick(now: now) {
    case .quiet:
      break
    case .stalled(let milliseconds, let line):
      session.logFreeze(
        "kind=client-stall view=\(id) stalled_ms=\(milliseconds) line=\(line) "
          + freezeStateText(now: now) + " " + session.freezeStateText(now: now))
    case .recovered(let milliseconds):
      session.logFreeze(
        "kind=client-recovered view=\(id) stalled_ms=\(milliseconds) frames=\(freeze.frames)")
    }
    checkFramesAreSeen(now: now)
  }

  /// Frames the host presents into a layer that is in no window, or has no size, change nothing
  /// on screen: the page looks frozen while both processes count frames. Agent pages are never
  /// shown and are left out.
  private func checkFramesAreSeen(now: UInt64) {
    guard !rendersOffscreen else { return }
    let showable = layerHost.isShowable && surfaceState?().inWindow == true
    switch freeze.tickUnseen(now: now, showable: showable) {
    case .quiet:
      break
    case .stalled(let milliseconds, _):
      session.logFreeze(
        "kind=client-frames-unseen view=\(id) unseen_ms=\(milliseconds) "
          + "layer=\(layerHost.stateText) " + freezeStateText(now: now))
    case .recovered(let milliseconds):
      session.logFreeze("kind=client-frames-seen view=\(id) unseen_ms=\(milliseconds)")
    }
  }

  /// What the app believes about this view, as `key=value` pairs. Never a URL or page content.
  func freezeStateText(now: UInt64) -> String {
    let surface = surfaceState?().text ?? "none"
    let report = lastHostReport.map {
      "\($0.kindName),age_ms:\(Self.ageMilliseconds(now, $0.receivedNanos))"
    }
    return [
      "waiting=\(freeze.waitingText)", "sent=\(freeze.inputsSent)",
      "unsent=\(freeze.inputsUnsent)", "frames=\(freeze.frames)",
      "frame_age_ms=\(Self.ageMilliseconds(now, freeze.lastFrameNanos))",
      "input_age_ms=\(Self.ageMilliseconds(now, freeze.lastInputNanos))",
      "status=\(freezeStatusName)",
      "told_host=visible:\(isVisible ? 1 : 0),focused:\(isFocused ? 1 : 0)",
      "loading=\(isLoading ? 1 : 0)", "prompts=\(pendingPrompts.count)",
      "size=\(Int(size.width))x\(Int(size.height))@\(scale)", "site=\(freezeSite)",
      "mode=\(layerHost.mode?.rawValue ?? "none")", "surface=\(surface)",
      "view_report=\(report ?? "none")",
    ].joined(separator: " ")
  }

  /// Milliseconds from `then` to `now`, or -1 when `then` is never.
  nonisolated static func ageMilliseconds(_ now: UInt64, _ then: UInt64) -> Int64 {
    guard then != 0 else { return -1 }
    return now > then ? Int64((now - then) / 1_000_000) : 0
  }

  /// The page's host name, or its scheme when it has none. Nothing else of the URL is logged.
  private var freezeSite: String {
    guard let url else { return "-" }
    let site = url.host() ?? url.scheme.map { "\($0):" } ?? "-"
    return String(site.unicodeScalars.filter { Self.siteCharacters.contains($0) }.prefix(63))
  }

  private nonisolated static let siteCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:_[]")

  private var freezeStatusName: String {
    switch status {
    case .waitingForHost: "waiting-for-host"
    case .creating: "creating"
    case .live: "live"
    case .unavailable: "unavailable"
    case .closed: "closed"
    }
  }

  /// Writes what was just told to the host about visibility or focus.
  func logFreezeTransition(_ what: String) {
    session.logFreeze(
      "kind=client-\(what) view=\(id) status=\(freezeStatusName) "
        + "surface=\(surfaceState?().text ?? "none")")
  }
}
