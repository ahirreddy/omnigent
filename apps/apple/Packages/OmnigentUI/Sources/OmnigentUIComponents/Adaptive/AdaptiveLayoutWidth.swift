public import SwiftUI

extension View {
  /// Sets the components' ``LayoutWidth`` from the environment: the horizontal size class on
  /// iOS (so a folded Duo is compact and an unfolded one regular), the container width on macOS.
  /// - Parameter compactBelow: On macOS, widths under this are compact.
  /// - Returns: The view with ``LayoutWidth`` set.
  public func adaptiveLayoutWidth(compactBelow: CGFloat = 560) -> some View {
    modifier(AdaptiveLayoutWidth(compactBelow: compactBelow))
  }

  /// Forces a ``LayoutWidth``, for previews, tests and hosts that decide it themselves.
  /// - Parameter width: The width class.
  /// - Returns: The view with ``LayoutWidth`` set.
  public func layoutWidth(_ width: LayoutWidth) -> some View {
    environment(\.layoutWidth, width)
  }
}

extension LayoutWidth {
  /// Points past the threshold a compact layout must grow before it is regular again: the
  /// compact layout can be a little narrower (a scroll bar, a column's minimum), and without
  /// the slack the class would flip on every layout pass at the threshold.
  nonisolated static let regularSlack: CGFloat = 24

  /// The class of a container `width` points wide, after `previous`.
  nonisolated static func measuring(_ width: CGFloat, compactBelow: CGFloat, previous: Self) -> Self
  {
    let threshold = previous == .compact ? compactBelow + regularSlack : compactBelow
    return width < threshold ? .compact : .regular
  }
}

private struct AdaptiveLayoutWidth: ViewModifier {
  let compactBelow: CGFloat
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var measured: LayoutWidth = .regular

  func body(content: Content) -> some View {
    #if os(iOS)
      content.environment(\.layoutWidth, sizeClass == .compact ? .compact : .regular)
    #else
      content
        .environment(\.layoutWidth, measured)
        .onGeometryChange(for: LayoutWidth.self) { [measured, compactBelow] proxy in
          LayoutWidth.measuring(proxy.size.width, compactBelow: compactBelow, previous: measured)
        } action: { width in
          #if DEBUG
            LoopProbe.record("layout width", "\(measured) -> \(width)")
          #endif
          measured = width
        }
    #endif
  }
}

#if os(iOS)
  extension View {
    /// Keeps a short window (a phone in landscape: compact vertical size class) at compact
    /// width, as every iPhone but the largest already is. Rotating a large iPhone then keeps the
    /// stack instead of rebuilding the conversation into split-view columns; tall windows (iPad,
    /// an unfolded Duo) keep their own size class.
    /// - Returns: The view with the horizontal size class it lays out by.
    public func shortWindowsStayCompact() -> some View {
      modifier(ShortWindowsStayCompact())
    }
  }

  struct ShortWindowsStayCompact: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical

    func body(content: Content) -> some View {
      content.environment(
        \.horizontalSizeClass,
        ShortWindowLayout.horizontalClass(horizontal: horizontal, vertical: vertical))
    }
  }
#endif

/// How a short window lays out (``View/shortWindowsStayCompact()`` on iOS).
nonisolated enum ShortWindowLayout {
  /// The horizontal size class to lay out by: compact whenever the window is short.
  static func horizontalClass(
    horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?
  ) -> UserInterfaceSizeClass? {
    vertical == .compact ? .compact : horizontal
  }
}
