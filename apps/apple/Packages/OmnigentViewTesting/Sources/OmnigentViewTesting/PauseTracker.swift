#if os(macOS)
  import Foundation
  import os

  /// The test bundle's load calls this from C, before any view pauses.
  @_cdecl("omnigent_view_testing_track_pauses")
  func trackPauses() {
    PauseTracker.install()
  }

  /// When the views' timed pauses end. Omnigent's views announce each pause as it begins (the
  /// test bundle's load asks them to), since the Swift runtime shows a test no `Task.sleep`.
  enum PauseTracker {
    /// The notification the views post, and the key of its length in seconds.
    static let pauseBegan = Notification.Name("OmnigentPauseBegan")
    static let secondsKey = "seconds"
    private static let ends = OSAllocatedUnfairLock(initialState: [CFAbsoluteTime]())
    private static let installation = OSAllocatedUnfairLock(initialState: false)

    /// Starts listening, once.
    static func install() {
      let isFirst = installation.withLock { installed in
        defer { installed = true }
        return !installed
      }
      guard isFirst else { return }
      let center = NotificationCenter.default
      center.addObserver(forName: pauseBegan, object: nil, queue: nil, using: notePause)
    }

    /// Notes when an announced pause ends.
    /// - Parameter note: The views' announcement.
    private static func notePause(_ note: Notification) {
      guard let seconds = note.userInfo?[secondsKey] as? Double, seconds > 0 else { return }
      noteEnd(CFAbsoluteTimeGetCurrent() + seconds)
    }

    /// Keeps an end, dropping those already passed.
    /// - Parameter end: When a pause ends, as an absolute time.
    static func noteEnd(_ end: CFAbsoluteTime) {
      let now = CFAbsoluteTimeGetCurrent()
      ends.withLock { ends in
        ends.removeAll { $0 <= now }
        ends.append(end)
      }
    }

    /// Whether a pause ends from now until `deadline`.
    /// - Parameter deadline: An absolute time.
    /// - Returns: Whether one does.
    static func hasPause(endingBefore deadline: CFAbsoluteTime) -> Bool {
      let now = CFAbsoluteTimeGetCurrent()
      return ends.withLock { ends in ends.contains { $0 > now && $0 < deadline } }
    }
  }
#endif
