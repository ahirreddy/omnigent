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

/// Reports the session whose chat is on screen, and whether its window has focus, when either
/// changes: a tab switch then renders this and not the window.
struct ViewedSessionReport: ViewModifier {
  let tabs: SessionTabGroups
  let isWindowFocused: Bool
  let report: (String?, Bool) -> Void

  func body(content: Content) -> some View {
    content
      .onChange(of: tabs.viewedSessionID) { _, viewed in report(viewed, isWindowFocused) }
      .onChange(of: isWindowFocused) { _, focused in report(tabs.viewedSessionID, focused) }
  }
}

/// Hands the host a page the model changed (a removed session, a tab opened in another session):
/// showing another session then renders this and not the window.
struct ShownPageReport: ViewModifier {
  let tabs: SessionTabGroups
  let changed: (SidebarDestination?) -> Void

  func body(content: Content) -> some View {
    content.onChange(of: tabs.page) { _, page in changed(page) }
  }
}

extension SessionTabGroups {
  /// The session whose chat is on screen, for notification suppression.
  var viewedSessionID: String? {
    guard let tabs = current else { return nil }
    let visible = tabs.visibleIDs.compactMap(tabs.tab)
    return visible.lazy.compactMap { tab -> String? in
      if case .chat(let id) = tab.content { return id }
      return nil
    }.first
  }
}
