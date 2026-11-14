#if os(macOS)
  public import Foundation

  extension OffscreenWindow {
    /// The controls' frames once three reads in a row agree, or the last read after `timeout`.
    /// A window still moving (a sheet sliding in, rows arriving) is then clicked where it rests.
    /// - Parameter timeout: The longest wait, in seconds.
    /// - Returns: The frames, as ``controlFrames`` lists them.
    public func restingControlFrames(timeout: TimeInterval = 2) -> [CGRect] {
      let deadline = Date().addingTimeInterval(timeout)
      var frames = controlFrames
      var unchanged = 0
      while unchanged < 2, Date() < deadline {
        settle(0.03)
        let latest = controlFrames
        unchanged = latest == frames ? unchanged + 1 : 0
        frames = latest
      }
      return frames
    }
  }
#endif
