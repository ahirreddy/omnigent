import SwiftUI

/// The sidebar's top rows: New session, Automations, Inbox, Canvas, Usage, and the native quick
/// filters (Running, Needs you). While the server's pages can't be read, a quiet row says so.
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
    if let failure = state.pagesFailure {
      SidebarPagesFailureRow(failure: failure, retry: actions.retryPages)
    }
    SidebarCountedRow(counts: counts) { counts in
      Label("Inbox", systemImage: "tray")
        .neutralSidebarIcon()
        .badge(counts.inboxBadge.map { Text($0) })
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

/// In place of Automations, Usage and Canvas while the pages the server offers could not be
/// read: a failure, unlike a server that turned them off, which shows no row at all.
struct SidebarPagesFailureRow: View {
  let failure: String
  let retry: (@MainActor () -> Void)?

  static let text = "Couldn\u{2019}t load Automations and other pages"

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
      Image(systemName: "exclamationmark.circle")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(Self.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      Spacer(minLength: 4)
      if let retry {
        Button("Retry", action: retry).controlSize(.small)
          .accessibilityIdentifier("sidebar-pages-retry")
      }
    }
    .help(failure)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("sidebar-pages-failure")
  }
}
