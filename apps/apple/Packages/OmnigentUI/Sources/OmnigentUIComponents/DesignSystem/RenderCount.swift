import OmnigentPlatform
import SwiftUI

extension View {
  /// Counts a body evaluation under `name` for the Debug frame monitor; does nothing in Release.
  func countsRenders(_ name: String) -> Self {
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
