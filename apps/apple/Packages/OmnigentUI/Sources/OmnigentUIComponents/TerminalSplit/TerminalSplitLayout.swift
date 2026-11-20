public import CoreGraphics

/// How a split divides its area: side by side (Split Right) or stacked (Split Down).
nonisolated public enum TerminalSplitAxis: String, Hashable, Codable, Sendable {
  /// Side by side, the new pane on the right.
  case columns
  /// Stacked, the new pane below.
  case rows
}

/// What a pane of a split Terminal view shows.
nonisolated public enum TerminalPaneKey: Hashable, Codable, Sendable {
  /// The session's own terminal (the harness's TUI), whatever its terminal id is now.
  case agent
  /// A shell the user split off, by terminal id.
  case shell(String)

  /// The shell's terminal id; `nil` for the agent's pane.
  public var shellID: String? {
    if case .shell(let id) = self { return id }
    return nil
  }
}

/// The split tree of a Terminal view (the web's `TerminalLayout`): leaves are panes, and a
/// split divides its area between two subtrees by `ratio`.
nonisolated public indirect enum TerminalSplitLayout: Hashable, Codable, Sendable {
  /// One pane.
  case pane(TerminalPaneKey)
  /// Two subtrees; `ratio` is the first one's share of the area.
  case split(axis: TerminalSplitAxis, ratio: Double, first: Self, second: Self)

  /// Neither side of a split shrinks below a quarter of its parent.
  public static let minimumRatio = 0.25
  /// Nor grows past three quarters.
  public static let maximumRatio = 0.75

  /// `ratio` within the allowed range; a ratio that is not a number (a zero-size area) is 0.5.
  public static func clamped(_ ratio: Double) -> Double {
    guard ratio.isFinite else { return 0.5 }
    return min(maximumRatio, max(minimumRatio, ratio))
  }

  /// The panes in reading order: left to right, top to bottom.
  public var keys: [TerminalPaneKey] {
    switch self {
    case .pane(let key): [key]
    case .split(_, _, let first, let second): first.keys + second.keys
    }
  }

  /// Splits `target` in two, with `newKey` right of or below it.
  public func splitting(
    _ target: TerminalPaneKey, with newKey: TerminalPaneKey, axis: TerminalSplitAxis
  ) -> Self {
    switch self {
    case .pane(let key):
      key == target ? .split(axis: axis, ratio: 0.5, first: self, second: .pane(newKey)) : self
    case .split(let splitAxis, let ratio, let first, let second):
      .split(
        axis: splitAxis, ratio: ratio, first: first.splitting(target, with: newKey, axis: axis),
        second: second.splitting(target, with: newKey, axis: axis))
    }
  }

  /// Drops `key`'s pane; its sibling takes the freed space. `nil` when nothing is left.
  public func removing(_ key: TerminalPaneKey) -> Self? {
    switch self {
    case .pane(let pane):
      return pane == key ? nil : self
    case .split(let axis, let ratio, let first, let second):
      let keptFirst = first.removing(key)
      let keptSecond = second.removing(key)
      guard let keptFirst else { return keptSecond }
      guard let keptSecond else { return keptFirst }
      return .split(axis: axis, ratio: ratio, first: keptFirst, second: keptSecond)
    }
  }

  /// Sets the ratio of the split at `path` (child indexes from the root), clamped.
  public func resizing(at path: [Int], to ratio: Double) -> Self {
    guard case .split(let axis, let current, let first, let second) = self else { return self }
    guard let index = path.first else {
      return .split(axis: axis, ratio: Self.clamped(ratio), first: first, second: second)
    }
    let rest = Array(path.dropFirst())
    return .split(
      axis: axis, ratio: current,
      first: index == 0 ? first.resizing(at: rest, to: ratio) : first,
      second: index == 1 ? second.resizing(at: rest, to: ratio) : second)
  }

  /// Whether every split's ratio is in range and no pane appears twice.
  var isValid: Bool {
    let keys = keys
    return Set(keys).count == keys.count && ratiosInRange
  }

  private var ratiosInRange: Bool {
    switch self {
    case .pane: true
    case .split(_, let ratio, let first, let second):
      ratio >= Self.minimumRatio && ratio <= Self.maximumRatio && first.ratiosInRange
        && second.ratiosInRange
    }
  }

  /// The panes' and dividers' rectangles in `area`.
  public func geometry(in area: CGRect) -> TerminalSplitGeometry {
    var geometry = TerminalSplitGeometry()
    place(in: area, path: [], into: &geometry)
    return geometry
  }

  private func place(in area: CGRect, path: [Int], into geometry: inout TerminalSplitGeometry) {
    switch self {
    case .pane(let key):
      geometry.panes.append(TerminalSplitGeometry.Pane(key: key, frame: area))
    case .split(let axis, let ratio, let first, let second):
      let (firstArea, secondArea) =
        axis == .columns
        ? area.divided(atDistance: area.width * ratio, from: .minXEdge)
        : area.divided(atDistance: area.height * ratio, from: .minYEdge)
      geometry.dividers.append(
        TerminalSplitGeometry.Divider(path: path, axis: axis, ratio: ratio, area: area))
      first.place(in: firstArea, path: path + [0], into: &geometry)
      second.place(in: secondArea, path: path + [1], into: &geometry)
    }
  }
}

/// Where a split tree puts its panes and dividers.
nonisolated public struct TerminalSplitGeometry: Hashable, Sendable {
  /// One pane's rectangle.
  public struct Pane: Hashable, Sendable {
    /// The pane.
    public var key: TerminalPaneKey
    /// Its rectangle.
    public var frame: CGRect
  }

  /// The boundary of one split, which resizes it.
  public struct Divider: Hashable, Sendable {
    /// Child indexes from the root to the split.
    public var path: [Int]
    /// Its axis: a `columns` divider is a vertical line.
    public var axis: TerminalSplitAxis
    /// The split's ratio.
    public var ratio: Double
    /// The area the split divides.
    public var area: CGRect

    /// Where the line sits along the axis.
    public var offset: CGFloat {
      axis == .columns ? area.minX + area.width * ratio : area.minY + area.height * ratio
    }

    /// The ratio a pointer at `location` asks for.
    public func ratio(at location: CGPoint) -> Double {
      let span = axis == .columns ? area.width : area.height
      guard span > 0 else { return ratio }
      let position = axis == .columns ? location.x - area.minX : location.y - area.minY
      return TerminalSplitLayout.clamped(position / span)
    }
  }

  /// The panes, in reading order.
  public var panes: [Pane] = []
  /// The dividers, outermost first.
  public var dividers: [Divider] = []
}

/// A session's split Terminal view: its tree and the pane the split actions target.
nonisolated public struct TerminalSplitState: Hashable, Codable, Sendable {
  /// The tree; always a split, as one pane is the unsplit view.
  public private(set) var layout: TerminalSplitLayout
  /// The pane the split and close actions target, and the keyboard's.
  public private(set) var focused: TerminalPaneKey

  /// A state, or `nil` for one that is not a valid split (restored as unsplit).
  /// - Parameters:
  ///   - layout: The tree.
  ///   - focused: The focused pane, which must be in the tree.
  public init?(layout: TerminalSplitLayout, focused: TerminalPaneKey) {
    guard case .split = layout, layout.isValid, layout.keys.contains(focused) else { return nil }
    self.layout = layout
    self.focused = focused
  }

  /// Splits `state`'s focused pane (the agent's in an unsplit view) with a new shell, which
  /// takes the focus.
  /// - Parameters:
  ///   - state: The current split; `nil` for the unsplit view.
  ///   - shellID: The new shell's terminal id.
  ///   - axis: Split Right or Split Down.
  /// - Returns: The new state; `state` itself when the shell is already a pane.
  public static func splitting(
    _ state: Self?, with shellID: String, axis: TerminalSplitAxis
  ) -> Self? {
    let layout = state?.layout ?? .pane(.agent)
    let newKey = TerminalPaneKey.shell(shellID)
    guard !layout.keys.contains(newKey) else { return state }
    let target = state?.focused ?? .agent
    return Self(layout: layout.splitting(target, with: newKey, axis: axis), focused: newKey)
  }

  /// Drops `key`'s pane: `nil` once one pane is left, the unsplit view.
  public func removing(_ key: TerminalPaneKey) -> Self? {
    guard let layout = layout.removing(key) else { return nil }
    let keys = layout.keys
    return Self(layout: layout, focused: keys.contains(focused) ? focused : keys[0])
  }

  /// The same split with the split at `path` resized.
  public func resizing(at path: [Int], to ratio: Double) -> Self {
    var resized = self
    resized.layout = layout.resizing(at: path, to: ratio)
    return resized
  }

  /// The same split with `key` focused, if it is a pane.
  public func focusing(_ key: TerminalPaneKey) -> Self {
    guard layout.keys.contains(key) else { return self }
    var focusedState = self
    focusedState.focused = key
    return focusedState
  }

  /// The next pane (`step` 1) or the previous one (-1) in reading order, wrapping.
  public func cycling(by step: Int) -> Self {
    let keys = layout.keys
    let index = keys.firstIndex(of: focused) ?? 0
    return focusing(keys[((index + step) % keys.count + keys.count) % keys.count])
  }

  /// Drops shell panes whose terminal is gone. A shell missing from `liveShellIDs` is dropped
  /// only when `isGone` says so, rather than not delivered yet.
  /// - Returns: The state; `nil` once one pane is left.
  public func reconciled(
    liveShellIDs: Set<String>, isGone: (String) -> Bool
  ) -> Self? {
    var state: Self? = self
    for case .shell(let id) in layout.keys where !liveShellIDs.contains(id) && isGone(id) {
      state = state?.removing(.shell(id))
    }
    return state
  }
}
