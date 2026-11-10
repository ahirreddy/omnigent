import Foundation
import Observation
import OmnigentPlatform
import os

/// Hands the transcript its rows at most once per ``interval``. A streamed reply changes the
/// rows for every delta (30 or more a second), and each change costs a whole SwiftUI update of
/// the transcript; the first change after a quiet spell shows at once, the rest of a burst
/// together on the next tick. While the transcript is out of view (a kept tab) it stops reading
/// until it shows again. A conversation's first page of rows waits (briefly) until its newest
/// answers are parsed off the main actor (``MarkdownWarmup``), so its first frame only lays out.
@MainActor
@Observable
final class TranscriptRowsPacer {
  typealias Rows = (rows: [Row], revision: UInt64)

  /// The shortest time between two updates: 20 a second.
  static let defaultInterval: Duration = .milliseconds(50)

  /// Counts published updates; the transcript reads it to be told about the next one.
  private(set) var published = 0
  /// A first page of rows waits for its markdown; the transcript still says it is loading.
  private(set) var isPreparing = false
  /// Parses the rows' markdown in the background, ahead of their first render.
  @ObservationIgnored let warmup = MarkdownWarmup()
  @ObservationIgnored private var hasPrepared = false
  @ObservationIgnored private var latest: Rows = ([], 0)
  @ObservationIgnored private var reader: LiveTranscriptRows?
  @ObservationIgnored private var isShown = true
  @ObservationIgnored private var isStale = false
  @ObservationIgnored private var lastPublished: ContinuousClock.Instant?
  @ObservationIgnored private var pending: Task<Void, Never>?
  @ObservationIgnored private let interval: Duration
  @ObservationIgnored private let preparingLimit: Duration
  @ObservationIgnored private let clock = ContinuousClock()

  /// Creates a pacer.
  /// - Parameters:
  ///   - interval: The shortest time between two updates.
  ///   - preparingLimit: The longest a first page of rows waits for its markdown.
  init(interval: Duration = defaultInterval, preparingLimit: Duration = .milliseconds(400)) {
    self.interval = interval
    self.preparingLimit = preparingLimit
  }

  /// The rows to render. Call it from the transcript's body, which is then told about the next
  /// update.
  /// - Parameter reader: Reads the rows.
  /// - Returns: The rows as of the last update.
  func rows(from reader: LiveTranscriptRows) -> Rows {
    self.reader = reader
    if lastPublished == nil {
      latest = track(reader)
      lastPublished = clock.now
    }
    _ = published
    return latest
  }

  /// Says whether the transcript is on screen. A hidden one keeps the rows it last showed, and
  /// takes what it missed when it shows again, without its body running for the change itself.
  /// - Parameter isShown: The transcript is on screen.
  func setShown(_ isShown: Bool) {
    self.isShown = isShown
    guard isShown, isStale else { return }
    isStale = false
    schedule(after: .zero)
  }

  /// Reads the rows and asks to hear about their next change.
  private func track(_ reader: LiveTranscriptRows) -> Rows {
    withObservationTracking {
      reader.read()
    } onChange: { [weak self] in
      Task { @MainActor in self?.rowsChanged() }
    }
  }

  private func rowsChanged() {
    guard isShown else {
      isStale = true
      return
    }
    guard pending == nil else { return }
    let elapsed = lastPublished.map { clock.now - $0 } ?? interval
    schedule(after: max(.zero, interval - elapsed))
  }

  /// Publishes after `delay`, in place of any update already waiting.
  func schedule(after delay: Duration) {
    pending?.cancel()
    pending = Task { [weak self] in
      if delay > .zero {
        do {
          try await Task.sleep(for: delay)
        } catch {
          // Cancelled by a newer schedule, which publishes instead.
          return
        }
      }
      self?.publish()
    }
  }

  private func publish() {
    pending = nil
    guard let reader else { return }
    guard isShown else {
      isStale = true
      return
    }
    if latest.rows.isEmpty, !hasPrepared, let ready = warmup.warm(reader.read().rows) {
      hasPrepared = true
      isPreparing = true
      let limit = preparingLimit
      pending = Task { [weak self] in
        await Self.wait(for: ready, atMost: limit)
        guard let self else { return }
        isPreparing = false
        if !Task.isCancelled { publish() }
      }
      return
    }
    latest = track(reader)
    lastPublished = clock.now
    published += 1
    PerformanceSignposts.transcript.emitEvent("rows published")
  }

  /// Returns when `task` ends or `limit` passes, whichever comes first.
  private static func wait(for task: Task<Void, Never>, atMost limit: Duration) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let once = ResumeOnce(continuation)
      Task { @MainActor in
        await task.value
        once.resume()
      }
      Task { @MainActor in
        try? await Task.sleep(for: limit)
        once.resume()
      }
    }
  }
}

/// Resumes a continuation the first time it is asked to.
@MainActor
private final class ResumeOnce {
  private var continuation: CheckedContinuation<Void, Never>?

  init(_ continuation: CheckedContinuation<Void, Never>) {
    self.continuation = continuation
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}
