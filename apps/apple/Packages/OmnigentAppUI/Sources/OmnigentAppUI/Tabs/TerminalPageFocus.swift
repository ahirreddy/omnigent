import OmnigentTerminalUI
import OmnigentUIComponents
import SwiftUI

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
