public import SwiftUI

/// When a scene coming out of the background is a return that reopens its server's streams.
public enum SceneReturn {
  /// Whether `previous` to `phase` brings a scene that was on screen before back from the
  /// background. A cold launch to open a link starts the scene in the background; the launch
  /// connect opens the streams, so that first move out of the background is not a return.
  /// - Parameters:
  ///   - previous: The phase before.
  ///   - phase: The new phase.
  ///   - hasBeenActive: The scene was active at some point before this change.
  /// - Returns: Whether the streams should reopen.
  public static func isReturn(
    from previous: ScenePhase, to phase: ScenePhase, hasBeenActive: Bool
  ) -> Bool {
    hasBeenActive && previous == .background && phase != .background
  }
}
