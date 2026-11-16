import Foundation

/// What the pacer reads about a surface's frames.
struct TerminalFrameProbe {
  /// Frames libghostty has begun drawing.
  var drawnFrames: @MainActor () -> Int
  /// The frame the layer holds now.
  var shownFrame: @MainActor () -> ObjectIdentifier?
  /// Whether the surface is in a window, where Core Animation shows its frames.
  var isInWindow: @MainActor () -> Bool
}

/// Holds remote output while a frame libghostty drew from earlier output has not reached the
/// layer yet.
///
/// On macOS libghostty draws on its own thread into a ring of three IOSurfaces, and hands each
/// finished frame to the main thread to put on the layer. A slot is free again as soon as the
/// GPU is done with it, not once Core Animation stops showing it. When the main thread falls a
/// frame behind (a window busy laying out a streaming chat), the renderer draws into the
/// IOSurface still on screen, which shows as tearing. Changing the screen only once the last
/// drawn frame is on the layer, and committed, keeps a full frame between the two.
@MainActor
final class TerminalOutputPacer {
  /// How often a held burst checks whether the frame reached the layer.
  static let pollInterval = Duration.milliseconds(2)
  /// The longest output is held. A frame the layer refuses (a size that no longer fits during
  /// a resize) never arrives.
  static let longestHold = Duration.milliseconds(50)

  private let probe: TerminalFrameProbe
  private let feed: @MainActor ([UInt8]) -> Void
  private let commit: @MainActor () -> Void
  /// Output waiting for the frame in flight.
  private(set) var pending: [UInt8] = []
  private var drawnAtFeed = 0
  private var shownAtFeed: ObjectIdentifier?
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

  /// Whether output can change the screen now: every frame drawn since the last output is on
  /// the layer. A frame not yet begun takes the new output with it.
  var canFeed: Bool {
    !probe.isInWindow() || probe.drawnFrames() == drawnAtFeed || probe.shownFrame() != shownAtFeed
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
    let shown = probe.shownFrame()
    if probe.isInWindow(), shown != shownAtFeed { commit() }
    drawnAtFeed = probe.drawnFrames()
    shownAtFeed = shown
    feed(bytes)
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
