import Foundation
import Observation

/// Hands the transcript its rows at most once per ``interval``. A streamed reply changes the
/// rows for every delta (30 or more a second), and each change costs a whole SwiftUI update of
/// the transcript; the first change after a quiet spell shows at once, the rest of a burst
/// together on the next tick. While the transcript is out of view (a kept tab) it stops reading
/// until it shows again.
@MainActor
@Observable
final class TranscriptRowsPacer {
  typealias Rows = (rows: [Row], revision: UInt64)

  /// The shortest time between two updates: 20 a second.
  static let defaultInterval: Duration = .milliseconds(50)

  /// Counts published updates; the transcript reads it to be told about the next one.
  private(set) var published = 0
  @ObservationIgnored private var latest: Rows = ([], 0)
  @ObservationIgnored private var reader: LiveTranscriptRows?
  @ObservationIgnored private var isShown = true
  @ObservationIgnored private var isStale = false
  @ObservationIgnored private var lastPublished: ContinuousClock.Instant?
  @ObservationIgnored private var pending: Task<Void, Never>?
  @ObservationIgnored private let interval: Duration
  @ObservationIgnored private let clock = ContinuousClock()

  /// Creates a pacer.
  /// - Parameter interval: The shortest time between two updates.
  init(interval: Duration = defaultInterval) {
    self.interval = interval
  }

  /// The rows to render. Call it from the transcript's body: while shown, the body is told
  /// about the next update; while hidden, it keeps the rows it last showed.
  /// - Parameters:
  ///   - reader: Reads the rows.
  ///   - isShown: The transcript is on screen.
  /// - Returns: The rows as of the last update.
  func rows(from reader: LiveTranscriptRows, isShown: Bool) -> Rows {
    self.reader = reader
    self.isShown = isShown
    if lastPublished == nil {
      latest = track(reader)
      lastPublished = clock.now
    } else if isShown, isStale {
      isStale = false
      // Not in this body: reading the rows here would subscribe it to every delta.
      schedule(after: .zero)
    }
    if isShown { _ = published }
    return latest
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

  private func schedule(after delay: Duration) {
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
    latest = track(reader)
    lastPublished = clock.now
    published += 1
  }
}
