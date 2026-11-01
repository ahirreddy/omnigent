public import Foundation
internal import OWLProtocol

/// Result of a find-in-page request.
nonisolated public struct FindResult: Hashable, Sendable {
  /// Total matches.
  public let matchCount: Int
  /// One-based index of the highlighted match, or nil when there is none.
  public let activeMatch: Int?

  /// Whether at least one match exists.
  public var matchFound: Bool { matchCount > 0 }
}

/// Things a view reports besides state changes.
nonisolated public enum WebViewEvent: Sendable, Hashable {
  /// The page asked for UI the web layer does not project yet; it was denied.
  case featureBlocked(feature: String, detail: String)
  /// The page tried to download a file.
  case downloadBlocked(URL?)
  /// The renderer process exited.
  case rendererTerminated(String)
  /// The first frame after creation was presented, this long after the view was created.
  case firstFramePresented(Duration)
}

/// Mouse cursor the page asks for.
nonisolated public enum WebCursor: Sendable, Hashable {
  /// Arrow.
  case pointer
  /// Pointing hand.
  case hand
  /// Text I-beam.
  case iBeam
  /// Crosshair.
  case crosshair
  /// Busy; shown as an arrow.
  case wait
  /// Help.
  case help
  /// Horizontal resize.
  case resizeLeftRight
  /// Vertical resize.
  case resizeUpDown
  /// Not allowed.
  case notAllowed
  /// Open hand.
  case grab
  /// Closed hand.
  case grabbing
  /// Hidden.
  case none

  private static let wireValues: [OWLCursor: Self] = [
    .hand: .hand, .iBeam: .iBeam, .cross: .crosshair, .wait: .wait, .help: .help,
    .resizeEastWest: .resizeLeftRight, .resizeNorthSouth: .resizeUpDown,
    .notAllowed: .notAllowed, .grab: .grab, .grabbing: .grabbing, .none: .none,
  ]

  init(wire value: UInt64) {
    self = OWLCursor(rawValue: value).flatMap { Self.wireValues[$0] } ?? .pointer
  }
}

/// Frame delivery counters for one view, for diagnostics and the rendering spike.
nonisolated public struct FrameStatistics: Sendable, Hashable {
  /// Frames shown.
  public var framesPresented = 0
  /// Frames the host dropped because every buffer was busy.
  public var framesDropped: UInt64 = 0
  /// Host paint callback to presentation, per frame, in microseconds. In IOSurface mode this
  /// ends when the client sets the layer contents; in remote-layer mode when the host commits.
  public var latencyMicroseconds: [Double] = []
  /// Host GPU copy time per frame, in microseconds.
  public var copyMicroseconds: [Double] = []

  mutating func record(latency: Double, copy: Double) {
    framesPresented += 1
    latencyMicroseconds.append(latency)
    copyMicroseconds.append(copy)
    if latencyMicroseconds.count > 600 {
      latencyMicroseconds.removeFirst(latencyMicroseconds.count - 600)
      copyMicroseconds.removeFirst(copyMicroseconds.count - 600)
    }
  }
}
