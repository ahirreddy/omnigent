import SwiftUI

/// Where the panes and the divider go for a width: the share, kept so both panes stay at least
/// ``TabSplitState/minimumPaneWidth``, or either side of a hinge that leaves both that wide.
nonisolated struct TabSplitLayout: Equatable {
  /// The coordinate space the divider is dragged in.
  static let space = "tab-split"
  /// How far VoiceOver's adjust moves the divider.
  static let adjustStep = 0.05

  /// The divider's fraction after VoiceOver adjusts it.
  /// - Parameters:
  ///   - fraction: The current fraction.
  ///   - direction: Increment or decrement.
  /// - Returns: The new fraction.
  static func adjusted(_ fraction: Double, direction: AccessibilityAdjustmentDirection) -> Double {
    fraction + (direction == .increment ? adjustStep : -adjustStep)
  }

  var leading: CGFloat
  var gap: CGFloat
  var trailing: CGFloat
  var isAtHinge = false

  init(width: CGFloat, fraction: Double, hinge: CGRect? = nil) {
    let minimum = TabSplitState.minimumPaneWidth
    if let hinge, hinge.minX >= minimum, width - hinge.maxX >= minimum {
      leading = hinge.minX
      gap = hinge.width
      trailing = width - hinge.maxX
      isAtHinge = true
      return
    }
    gap = TabSplitMetrics.divider
    let room = max(0, width - gap)
    let wanted = (room * TabSplitState.clamp(fraction)).rounded()
    leading = min(max(wanted, minimum), max(minimum, room - minimum))
    trailing = max(0, room - leading)
  }

  /// A pane's frame in `bounds`, whose width the layout was made for.
  func frame(of pane: TabPane, in bounds: CGRect) -> CGRect {
    CGRect(
      x: bounds.minX + (pane == .leading ? 0 : leading + gap), y: bounds.minY,
      width: pane == .leading ? leading : trailing, height: bounds.height)
  }

  /// The pane at a horizontal position; none on the divider.
  func pane(at position: CGFloat) -> TabPane? {
    if position < leading { return .leading }
    return position >= leading + gap ? .trailing : nil
  }

  /// The hinge's frame when it splits the content side by side.
  static func hinge(in proxy: GeometryProxy) -> CGRect? {
    #if os(iOS)
      if #available(iOS 27.1, *) { return proxy.sideBySideHinge() }
    #endif
    return nil
  }

  /// The left pane's share for a divider dragged to `position`.
  static func fraction(at position: CGFloat, width: CGFloat) -> Double {
    guard width > 0 else { return 0.5 }
    let minimum = TabSplitState.minimumPaneWidth
    let clamped = min(max(position, minimum), max(minimum, width - minimum))
    return TabSplitState.clamp(Double(clamped / width))
  }
}
