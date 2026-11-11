import SwiftUI

extension View {
  /// On Mac, lays the view out below the window's title bar and toolbar with nothing drawn
  /// under them: the tabs float there, and a row, a page or a terminal under them is covered.
  /// Elsewhere the view is unchanged.
  /// - Returns: The view.
  @ViewBuilder func belowTitlebar() -> some View {
    #if os(macOS)
      modifier(BelowTitlebar())
    #else
      self
    #endif
  }
}

#if os(macOS)
  /// Turns the title bar's safe area into room above the view. Scroll views and backgrounds
  /// reach into a safe area; with none left above them, they end where the tabs do.
  private struct BelowTitlebar: ViewModifier {
    /// The title bar and toolbar's height, once a layout has measured it.
    @State private var titlebarHeight: CGFloat = 0

    func body(content: Content) -> some View {
      content
        .padding(.top, titlebarHeight)
        .ignoresSafeArea(.container, edges: .top)
        // The toolbar's height: it changes in full screen, never with a scroll or a resize.
        .onGeometryChange(for: CGFloat.self) {
          $0.safeAreaInsets.top
        } action: { height in
          LoopProbe.record("titlebar height", "\(titlebarHeight) -> \(height)")
          if titlebarHeight != height { titlebarHeight = height }
        }
    }
  }
#endif
