import OmnigentPlatform
import SwiftUI

extension View {
  /// Counts a body evaluation under `name` for the Debug frame monitor; does nothing in Release.
  func countsRenders(_ name: String) -> Self {
    #if DEBUG
      FrameMonitor.count(name)
    #endif
    return self
  }
}
