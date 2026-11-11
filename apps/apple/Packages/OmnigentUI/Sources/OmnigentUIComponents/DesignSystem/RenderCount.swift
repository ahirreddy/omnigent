import OmnigentPlatform
public import SwiftUI
import Synchronization

extension View {
  /// Counts a body evaluation under `name` for the Debug frame monitor; does nothing in Release.
  /// - Parameter name: The scope's name in the render counts.
  /// - Returns: The view, unchanged.
  public func countsRenders(_ name: String) -> Self {
    #if DEBUG
      FrameMonitor.count(name)
      RenderTally.count(name)
    #endif
    return self
  }
}

#if DEBUG
  /// Counts body evaluations by name while a test records them, so a test can say what an update
  /// re-rendered. Nothing is recorded otherwise.
  @MainActor
  enum RenderTally {
    private static var isRecording = false
    private static var counts: [String: Int] = [:]

    /// Counts one render of `name` while recording.
    static func count(_ name: String) {
      if isRecording { counts[name, default: 0] += 1 }
    }

    /// Runs `update` and says what rendered during it.
    /// - Parameter update: The change to measure, with the layout pass that applies it.
    /// - Returns: The renders, by name.
    static func recording(_ update: () -> Void) -> [String: Int] {
      counts = [:]
      isRecording = true
      defer { isRecording = false }
      update()
      return counts
    }
  }
#endif

/// Counts calls of the app's own layouts by name while a Debug test records them, so a test can
/// say what a change measured and placed. Nothing is recorded otherwise, or in Release.
nonisolated enum LayoutTally {
  /// Counts one call of `name` while recording. A layout is not bound to the main actor.
  static func count(_ name: String) {
    #if DEBUG
      recorded.withLock { tally in
        if tally.isRecording { tally.counts[name, default: 0] += 1 }
      }
    #endif
  }

  #if DEBUG
    /// The calls so far, while a test records.
    private static let recorded = Mutex<(isRecording: Bool, counts: [String: Int])>((false, [:]))

    /// Runs `update` and says which layouts ran during it.
    /// - Parameter update: The change to measure, with the layout pass that applies it.
    /// - Returns: The calls, by name.
    static func recording(_ update: () throws -> Void) rethrows -> [String: Int] {
      recorded.withLock { $0 = (true, [:]) }
      defer { recorded.withLock { $0.isRecording = false } }
      try update()
      return recorded.withLock { $0.counts }
    }
  #endif
}
