internal import OWLProtocol
internal import os

extension Logger {
  /// Freeze diagnostics. Read with
  /// `log show --last 30m --predicate 'subsystem BEGINSWITH "ai.omnigent.weblayer"'`.
  static let freeze = Logger(subsystem: "ai.omnigent.weblayer", category: "freeze")
}

/// The client's own evidence that a page is frozen: input was sent and no frame came back. It
/// needs nothing from the host, so it still speaks when the host is what is stuck. Times are
/// uptime nanoseconds from the caller; the rules are the host's (owl_freeze.h).
nonisolated struct FreezeDetector: Sendable {
  /// What a tick found.
  enum Verdict: Equatable, Sendable {
    case quiet
    /// Input has waited this long for a frame; `line` is the place in the reporting schedule.
    case stalled(milliseconds: UInt64, line: UInt32)
    /// A frame arrived after a reported stall of this length.
    case recovered(milliseconds: UInt64)
  }

  /// Input messages sent to the host, and input that was not sent because the view was not live.
  private(set) var inputsSent: UInt64 = 0
  private(set) var inputsUnsent: UInt64 = 0
  private(set) var lastInputNanos: UInt64 = 0
  /// The first input that expects a frame since the last frame; 0 when nothing waits.
  private(set) var unansweredSinceNanos: UInt64 = 0
  /// Input sent since the last frame, by `OWLInputClass`.
  private(set) var waiting = InlineArray<7, UInt32>(repeating: 0)
  private(set) var frames: UInt64 = 0
  private(set) var lastFrameNanos: UInt64 = 0
  private var waitingTotal: UInt32 = 0
  private var expectantInputs: UInt64 = 0
  private var episode = owl_stall_episode()
  private var framesAtUnseenTick: UInt64 = 0
  private var unseenSinceNanos: UInt64 = 0
  private var unseenEpisode = owl_stall_episode()

  /// Whether input is waiting for a frame.
  var isWaiting: Bool { unansweredSinceNanos != 0 }

  mutating func noteInput(_ input: OWLInputClass, sent: Bool, now: UInt64) {
    guard sent else {
      inputsUnsent += 1
      return
    }
    inputsSent += 1
    lastInputNanos = now
    let index = Int(input.rawValue)
    if waiting.indices.contains(index) { waiting[index] &+= 1 }
    waitingTotal &+= 1
    guard owl_input_expects_frame(input) else { return }
    expectantInputs += 1
    if unansweredSinceNanos == 0 { unansweredSinceNanos = now }
  }

  mutating func noteFrame(now: UInt64) {
    frames += 1
    lastFrameNanos = now
    guard waitingTotal != 0 else { return }
    waitingTotal = 0
    unansweredSinceNanos = 0
    waiting = InlineArray(repeating: 0)
  }

  /// Advances the detector by one tick of the client's timer.
  mutating func tick(now: UInt64) -> Verdict {
    let step = owl_stall_advance(
      episode, now, unansweredSinceNanos, OWL_STALL_VIEW_SECONDS, expectantInputs, true)
    episode = step.episode
    let milliseconds = now > step.since_nanos ? (now - step.since_nanos) / 1_000_000 : 0
    switch step.action {
    case .report: return .stalled(milliseconds: milliseconds, line: step.line)
    case .ended: return .recovered(milliseconds: milliseconds)
    default: return .quiet
    }
  }

  /// Advances the check for frames nobody can see: they keep arriving while the layer that
  /// shows them is in no window or has no size. Reported once, and once more when it ends.
  mutating func tickUnseen(now: UInt64, showable: Bool) -> Verdict {
    let arrived = frames != framesAtUnseenTick
    framesAtUnseenTick = frames
    if showable || !arrived {
      unseenSinceNanos = 0
    } else if unseenSinceNanos == 0 {
      unseenSinceNanos = now
    }
    let step = owl_stall_advance(
      unseenEpisode, now, unseenSinceNanos, OWL_STALL_VIEW_SECONDS, 0, true)
    unseenEpisode = step.episode
    let milliseconds = now > step.since_nanos ? (now - step.since_nanos) / 1_000_000 : 0
    switch step.action {
    case .report: return .stalled(milliseconds: milliseconds, line: step.line)
    case .ended: return .recovered(milliseconds: milliseconds)
    default: return .quiet
    }
  }

  /// The waiting input as `click:1,wheel:0,...`, in the order the host writes it.
  var waitingText: String {
    let names = ["click", "wheel", "key", "move", "text", "drag", "keyup"]
    return names.enumerated().map { "\($0.element):\(waiting[$0.offset])" }.joined(separator: ",")
  }
}

/// A health report from the host's freeze watch, as the client last received it.
nonisolated struct HostHealthReport: Equatable, Sendable {
  /// `OWLHealthKind`, raw: a newer host may send kinds this client does not know.
  var kind: UInt64
  var milliseconds: UInt64
  var receivedNanos: UInt64

  /// The kind as the host names it in its lines.
  var kindName: String {
    switch OWLHealthKind(rawValue: kind) {
    case .viewStall: "view-stall"
    case .viewRecovered: "view-recovered"
    case .rendererProbe: "renderer-probe"
    case .rendererUnresponsive: "renderer-unresponsive"
    case .rendererResponsive: "renderer-responsive"
    case .hostStall: "host-stall"
    case .hostRecovered: "host-recovered"
    case .channelBacklog: "channel-backlog"
    case .channelDrained: "channel-drained"
    default: "kind-\(kind)"
    }
  }
}

/// What the hosting view knows that its `WebView` does not: whether clicks and typing can reach
/// the page at all.
nonisolated struct WebSurfaceState: Equatable, Sendable {
  var inWindow = false
  var windowVisible = false
  var windowIsKey = false
  var isHidden = false
  var isFirstResponder = false
  /// The class that has the keyboard instead; never anything it holds.
  var firstResponder = "none"

  var text: String {
    "window:\(inWindow ? 1 : 0),on_screen:\(windowVisible ? 1 : 0),key:\(windowIsKey ? 1 : 0)"
      + ",hidden:\(isHidden ? 1 : 0),first_responder:\(isFirstResponder ? 1 : 0)"
      + ",keyboard_at:\(firstResponder)"
  }
}
