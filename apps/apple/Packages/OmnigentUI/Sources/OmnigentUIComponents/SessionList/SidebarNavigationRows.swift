import SwiftUI

/// The sidebar's top rows: New session, Automations, Inbox, Canvas, Usage, and the native quick
/// filters (Running, Needs you).
struct SidebarNavigationRows: View {
  let state: SidebarViewState
  let selection: SidebarDestination?
  let actions: SidebarActions

  var body: some View {
    Label("New session", systemImage: "plus.bubble")
      .neutralSidebarIcon()
      .fontWeight(.medium)
      .tag(SidebarDestination.newSession)
      .sidebarSelection(selection == .newSession)
      .accessibilityIdentifier("sidebar-new-session")
    if state.showsAutomations {
      Label("Automations", systemImage: "clock")
        .neutralSidebarIcon()
        .tag(SidebarDestination.automations)
        .sidebarSelection(selection == .automations)
        .accessibilityIdentifier("sidebar-automations")
    }
    Label("Inbox", systemImage: "tray")
      .neutralSidebarIcon()
      .badge(state.inboxCount)
      .tag(SidebarDestination.inbox)
      .sidebarSelection(selection == .inbox)
      .accessibilityIdentifier("sidebar-inbox")
    if state.showsCanvas {
      Label("Canvas", systemImage: "square.grid.2x2")
        .neutralSidebarIcon()
        .tag(SidebarDestination.canvas)
        .sidebarSelection(selection == .canvas)
        .accessibilityIdentifier("sidebar-canvas")
    }
    if state.showsUsage {
      Label("Usage", systemImage: "creditcard")
        .neutralSidebarIcon()
        .tag(SidebarDestination.usage)
        .sidebarSelection(selection == .usage)
        .accessibilityIdentifier("sidebar-usage")
    }
    if let setQuickFilter = actions.setQuickFilter {
      QuickFilterRow(
        filter: .running, isActive: state.quickFilter == .running,
        count: state.list.filterCounts[.running]
      ) {
        setQuickFilter(state.quickFilter == .running ? nil : .running)
      }
      QuickFilterRow(
        filter: .needsResponse, isActive: state.quickFilter == .needsResponse,
        count: state.list.filterCounts[.needsResponse]
      ) {
        setQuickFilter(state.quickFilter == .needsResponse ? nil : .needsResponse)
      }
    }
  }
}
