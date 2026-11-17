import Foundation

/// What the pacer reads about a surface's frames.
struct TerminalFrameProbe {
  /// Times libghostty's renderer has taken the terminal's state for a frame.
  var updatedFrames: @MainActor () -> Int
  /// Frames put on the layer. The layer's IOSurface alone can't tell: the renderer's ring of
  /// IOSurfaces brings each one back.
  var shownFrames: @MainActor () -> Int
  /// Whether the surface is in a window, where Core Animation shows its frames.
  var isInWindow: @MainActor () -> Bool
}

/// Holds remote output while a frame libghostty drew from earlier output has not reached the
/// layer yet.
///
/// On macOS libghostty draws on its own thread and hands each finished frame to the main thread
/// to put on the layer. While the main thread runs behind (a window busy laying out a streaming
/// chat), frames drawn meanwhile can't be shown, and the patched renderer skips them rather
/// than draw into an IOSurface on screen (DESIGN.md, "Output"). Changing the screen only once
/// the last frame is on the layer, and committed, makes a burst of output one frame instead.
@MainActor
final class TerminalOutputPacer {
  /// How often held output checks whether the frame reached the layer.
  static let pollInterval = Duration.milliseconds(2)
  /// The longest output is held: about two display refreshes. Output that changes nothing on
  /// screen (a title) draws no frame, and a frame the layer refuses (a size that no longer
  /// fits during a resize) never arrives.
  static let longestHold = Duration.milliseconds(34)

  private let probe: TerminalFrameProbe
  private let feed: @MainActor ([UInt8]) -> Void
  private let commit: @MainActor () -> Void
  /// Output waiting for the frame in flight.
  private(set) var pending: [UInt8] = []
  private var updatedAtFeed = 0
  private var shownAtFeed = 0
  /// The output so far left synchronized output on, so libghostty draws nothing from it yet.
  private var isSynchronizing = false
  private var waiter: Task<Void, Never>?

  /// - Parameters:
  ///   - probe: Reads the surface's frames.
  ///   - feed: Parses output into the surface.
  ///   - commit: Commits the layer changes made so far, so a frame put on the layer shows.
  init(
    probe: TerminalFrameProbe, feed: @escaping @MainActor ([UInt8]) -> Void,
    commit: @escaping @MainActor () -> Void
  ) {
    self.probe = probe
    self.feed = feed
    self.commit = commit
  }

  isolated deinit {
    waiter?.cancel()
  }

  /// Whether output can change the screen now: no frame is on its way to the layer. Output
  /// the renderer has not taken yet, or held in a synchronized update, joins the next frame.
  var canFeed: Bool {
    !probe.isInWindow() || isSynchronizing || probe.updatedFrames() == updatedAtFeed
      || probe.shownFrames() != shownAtFeed
  }

  /// Parses `bytes` now, or once the frame in flight is on the layer. Order is kept.
  func submit(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    pending.append(contentsOf: bytes)
    if waiter == nil, canFeed {
      flush()
    } else {
      waitForTheLayer()
    }
  }

  /// Parses everything held.
  func flush() {
    guard !pending.isEmpty else { return }
    let bytes = pending
    pending = []
    // A frame put on the layer since the last output is committed before the next is drawn.
    let shown = probe.shownFrames()
    if probe.isInWindow(), shown != shownAtFeed { commit() }
    updatedAtFeed = probe.updatedFrames()
    shownAtFeed = shown
    isSynchronizing = Self.leavesSynchronizedOutputOn(bytes, from: isSynchronizing)
    feed(bytes)
  }

  /// Whether synchronized output (DEC mode 2026) is on after `bytes`, given that it was
  /// `isOn` before them. A reset (RIS) turns it off. A mode change split across two outputs,
  /// or set together with other modes, is not seen; output then waits as for any frame.
  static func leavesSynchronizedOutputOn(_ bytes: [UInt8], from isOn: Bool) -> Bool {
    let mode = Array("[?2026".utf8)
    var state = isOn
    var start = bytes.startIndex
    while let escape = bytes[start...].firstIndex(of: 0x1B) {
      let rest = bytes[(escape + 1)...]
      if rest.first == UInt8(ascii: "c") {
        state = false
      } else if rest.starts(with: mode), let final = rest.dropFirst(mode.count).first {
        if final == UInt8(ascii: "h") { state = true }
        if final == UInt8(ascii: "l") { state = false }
      }
      start = escape + 1
    }
    return state
  }

  private func waitForTheLayer() {
    guard waiter == nil else { return }
    let deadline = ContinuousClock.now + Self.longestHold
    waiter = Task { [weak self] in
      while self?.isHolding(until: deadline) == true {
        do {
          try await Task.sleep(for: Self.pollInterval)
        } catch {
          // Cancelled: the surface is going away and its output with it.
          return
        }
      }
      self?.endWait()
    }
  }

  private func isHolding(until deadline: ContinuousClock.Instant) -> Bool {
    !canFeed && ContinuousClock.now < deadline
  }

  private func endWait() {
    waiter = nil
    flush()
  }
}
