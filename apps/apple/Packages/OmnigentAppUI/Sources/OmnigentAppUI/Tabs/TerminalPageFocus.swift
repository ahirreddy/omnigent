import OmnigentTerminalUI
import OmnigentUIComponents
public import SwiftUI

#if os(macOS)
  public import AppKit
#endif

/// Puts the keyboard in a terminal page's surface when its tab shows in the focused pane, and
/// gives it up when a kept tab hides, so typing reaches the terminal without a click.
struct TerminalPageFocus: ViewModifier {
  let surface: TerminalSurfaceController?
  @Environment(\.isTabContentHidden) private var isHidden
  @Environment(\.isActiveTabPane) private var isActivePane

  func body(content: Content) -> some View {
    content.terminalKeyboardFocus(surface, isShown: !isHidden, isActive: isActivePane)
  }
}

#if os(macOS)
  /// The same for a tab page that is another view taking typing, such as a browser page.
  public struct TabPageKeyboardFocus: ViewModifier {
    private let view: NSView?
    @Environment(\.isTabContentHidden) private var isHidden
    @Environment(\.isActiveTabPane) private var isActivePane

    /// Creates the modifier.
    /// - Parameter view: The view that takes typing; `nil` while the page has none, or leaves
    ///   the keyboard to a field of its own.
    public init(view: NSView?) {
      self.view = view
    }

    /// The page, taking the keyboard as its tab shows.
    public func body(content: Content) -> some View {
      content.keyboardFocusOnShow(view, isShown: !isHidden, isActive: isActivePane)
    }
  }
#endif
