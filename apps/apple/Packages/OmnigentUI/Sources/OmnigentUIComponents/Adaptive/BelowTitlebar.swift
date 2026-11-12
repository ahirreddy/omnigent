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
  /// Holds the view one pixel short of the title bar. A scroll view, a split view or a background
  /// reaches into a safe area only from a view that touches its edge, so nothing in this one does:
  /// each page starts where the tabs end, with no top inset left. Nothing is measured.
  private struct BelowTitlebar: ViewModifier {
    @Environment(\.pixelLength) private var pixelLength

    func body(content: Content) -> some View {
      content.padding(.top, pixelLength)
    }
  }
#endif
