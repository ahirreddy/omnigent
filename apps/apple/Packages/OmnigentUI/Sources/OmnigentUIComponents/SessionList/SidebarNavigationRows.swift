import SwiftUI

/// The sidebar's top rows: New session, Automations, Inbox, Canvas, Usage, and the native quick
/// filters (Running, Needs you).
struct SidebarNavigationRows: View {
  let state: SidebarViewState
  let selection: SidebarDestination?
  let actions: SidebarActions

  var body: some View {
    let counts: @MainActor () -> SidebarCounts = { actions.live?.counts() ?? state.counts }
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
    SidebarCountedRow(counts: counts) { counts in
      Label("Inbox", systemImage: "tray")
        .neutralSidebarIcon()
        .badge(counts.inbox)
    }
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
      quickFilter(.running, counts: counts, set: setQuickFilter)
      quickFilter(.needsResponse, counts: counts, set: setQuickFilter)
    }
  }

  private func quickFilter(
    _ filter: SessionFilter, counts: @escaping @MainActor () -> SidebarCounts,
    set: @escaping @MainActor (SessionFilter?) -> Void
  ) -> some View {
    SidebarCountedRow(counts: counts) { counts in
      QuickFilterRow(
        filter: filter, isActive: state.quickFilter == filter, count: counts.filters[filter]
      ) {
        set(state.quickFilter == filter ? nil : filter)
      }
    }
  }
}

/// A top row that shows a count. The count is read in this body, so a new one draws this row
/// and not the list around it.
private struct SidebarCountedRow<Row: View>: View {
  let counts: @MainActor () -> SidebarCounts
  @ViewBuilder let row: (SidebarCounts) -> Row

  var body: some View { row(counts()) }
}
