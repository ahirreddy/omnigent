public import SwiftUI

// The parts of the shell that read what the window shows, each in a body of its own: the
// selection and the tabs then render the part that shows them, and not the shell.

/// The window's tabs, for the views that show them to read.
public struct ShellTabs {
  let isShown: () -> Bool
  let content: () -> TabStripContent

  /// Creates the tabs.
  /// - Parameters:
  ///   - isShown: Whether the window shows tabs now; a page without a session has none.
  ///   - content: The tabs and their actions, read by the strip and its controls.
  public init(isShown: @escaping () -> Bool, content: @escaping () -> TabStripContent) {
    self.isShown = isShown
    self.content = content
  }
}

/// What the detail column is built from.
enum ShellDetail<Detail: View> {
  /// A detail for the selected destination.
  case selected((SidebarDestination?) -> Detail)
  /// A detail that reads what it shows itself.
  case unselected(() -> Detail)
}

/// A detail built for the selection, which it reads here.
struct SelectedDetail<Detail: View>: View {
  @Binding var selection: SidebarDestination?
  let detail: (SidebarDestination?) -> Detail

  var body: some View {
    detail(selection)
  }
}

/// The detail's titlebar: the tab strip and its controls where there is room, a Tabs button at
/// compact widths, and nothing on a page without tabs.
struct TitlebarTabs: ViewModifier {
  let tabs: ShellTabs?
  let space: TitlebarStripSpace
  let isSidebarHidden: Bool

  @Environment(\.horizontalSizeClass) private var sizeClass

  func body(content: Content) -> some View {
    // Chats sit under the strip at this width whether or not a page covers them, so a page
    // that comes or goes changes nothing they read.
    let hasStrip = tabs != nil && sizeClass != .compact
    let shown = tabs.flatMap { $0.isShown() ? $0.content : nil }
    let showsStrip = hasStrip && shown != nil
    return
      content
      .environment(\.tabsInTitlebar, hasStrip)
      .toolbar { toolbar(shown, showsStrip: showsStrip) }
      .modifier(TitlelessToolbar(isActive: showsStrip))
  }

  @ToolbarContentBuilder
  private func toolbar(_ tabs: (() -> TabStripContent)?, showsStrip: Bool) -> some ToolbarContent {
    if let tabs {
      if showsStrip {
        ToolbarItem(placement: .navigation) {
          TitlebarTabStrip(tabs: tabs, space: space, isSidebarHidden: isSidebarHidden)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        // New Tab sits by the trailing items, not wherever the tabs end.
        ToolbarItem(placement: .primaryAction) {
          ObservationScope("tab controls") {
            let tabs = tabs()
            TabStripControls(state: tabs.state, actions: tabs.actions)
          }
        }
        .sharedBackgroundVisibility(.hidden)
      } else {
        ToolbarItem(placement: Self.switcherPlacement) {
          ObservationScope("tab switcher") {
            let tabs = tabs()
            TabSwitcherButton(state: tabs.state, actions: tabs.actions)
          }
        }
      }
    }
  }

  /// Compact widths: beside the back button, where the bar never folds it into its overflow.
  private static var switcherPlacement: ToolbarItemPlacement {
    #if os(iOS)
      .topBarLeading
    #else
      .automatic
    #endif
  }
}
