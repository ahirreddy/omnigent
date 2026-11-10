import OmnigentUIComponents
import SwiftUI

// What a connected window does with its tabs besides showing them. Each reads the tabs in its
// own body, so a tab's title or status that changes renders that modifier and not the window.

/// Publishes the tab menu commands for the window.
struct TabCommandsPublishing: ViewModifier {
  let tabs: WindowTabs
  let relay: FocusedActionsRelay<TabCommandActions>

  func body(content: Content) -> some View {
    content.focusedSceneValue(\.tabCommands, relay.publish(tabs.commands))
  }
}

/// A background tab whose work settles gets the unread dot until it is shown.
struct BusyTabsReport: ViewModifier {
  let tabs: WindowTabs

  func body(content: Content) -> some View {
    let busy = tabs.store.map { tabs.state($0).busyIDs } ?? []
    return content.onChange(of: busy, initial: true) { _, busy in
      tabs.store?.noteBusy(busy)
    }
  }
}

/// Presents the window's tab overview.
struct WindowTabOverview: ViewModifier {
  let tabs: WindowTabs
  @Binding var isPresented: Bool

  func body(content: Content) -> some View {
    let strip = tabs.strip
    return content.tabOverview(
      isPresented: $isPresented, state: strip?.state ?? TabsState(),
      actions: strip?.actions ?? TabActions())
  }
}
