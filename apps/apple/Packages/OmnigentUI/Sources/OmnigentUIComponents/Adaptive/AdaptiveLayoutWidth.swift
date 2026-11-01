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
        .onGeometryChange(for: LayoutWidth.self) { proxy in
          proxy.size.width < compactBelow ? .compact : .regular
        } action: { width in
          measured = width
        }
    #endif
  }
}
