import Foundation
import OmnigentUIComponents

/// Turns the tabs saved per window (format 1, when tabs spanned sessions) into per-session
/// groups and each window's page.
nonisolated enum TabMigration {
  /// One old window's tabs as session groups.
  struct Grouped: Equatable {
    /// What the window showed: its selected tab's session, or a session-less page.
    var page: AppTabContent?
    /// Each session's tabs.
    var groups: [String: TabWindowSnapshot]
  }

  /// Groups old windows' tabs by session. A session in several windows keeps the most recently
  /// saved window's tabs.
  /// - Parameter windows: The old windows.
  /// - Returns: Each window's page and each session's tabs.
  static func migrate(_ windows: [LegacyWindowRecord]) -> (
    windows: [TabWindowRecord], sessions: [String: TabGroupRecord]
  ) {
    var sessions: [String: TabGroupRecord] = [:]
    var records: [TabWindowRecord] = []
    for window in windows.sorted(by: { $0.savedAt > $1.savedAt }) {
      let grouped = group(window.snapshot)
      for (sessionID, snapshot) in grouped.groups where sessions[sessionID] == nil {
        let normalized = SessionTabGroups.normalized(snapshot, for: sessionID)
        guard !SessionTabGroups.isDefault(normalized) else { continue }
        sessions[sessionID] = TabGroupRecord(
          savedAt: window.savedAt, snapshot: normalized, skipped: window.skipped)
      }
      records.append(
        TabWindowRecord(
          window: window.window, launch: window.launch, savedAt: window.savedAt,
          page: grouped.page))
    }
    return (records, sessions)
  }

  /// One window's tabs by session. A browser tab joins the session of the tab before it in the
  /// strip (it opened from there), else of the first session tab after it; new-tab pages and
  /// session-less pages are dropped. The selection and the split stay where their tabs went.
  /// - Parameter snapshot: The window's tabs.
  /// - Returns: The window's page and the groups.
  static func group(_ snapshot: TabWindowSnapshot) -> Grouped {
    let owners = owners(of: snapshot.tabs)
    var groups: [String: TabWindowSnapshot] = [:]
    for tab in snapshot.tabs {
      guard let sessionID = owners[tab.id] else { continue }
      groups[sessionID, default: TabWindowSnapshot()].tabs.append(tab)
    }
    let selected = snapshot.tabs.first { $0.id == snapshot.selectedID }
    let page: AppTabContent? =
      selected.flatMap { owners[$0.id] }.map { .chat(sessionID: $0) }
      ?? selected.flatMap { $0.content.destination }.map(AppTabContent.init)
    for (sessionID, group) in groups {
      groups[sessionID] = arranged(group, from: snapshot, sessionID: sessionID, page: page)
    }
    return Grouped(page: page, groups: groups)
  }

  /// The session each tab goes to.
  private static func owners(of tabs: [AppTab]) -> [String: String] {
    var owners: [String: String] = [:]
    var previous: String?
    var waiting: [String] = []
    for tab in tabs {
      if let sessionID = tab.content.sessionID {
        owners[tab.id] = sessionID
        for id in waiting { owners[id] = sessionID }
        waiting = []
        previous = sessionID
      } else if case .browser = tab.content {
        if let previous { owners[tab.id] = previous } else { waiting.append(tab.id) }
      }
    }
    return owners
  }

  /// A group's selection, closed tabs and split, from the window's.
  private static func arranged(
    _ group: TabWindowSnapshot, from window: TabWindowSnapshot, sessionID: String,
    page: AppTabContent?
  ) -> TabWindowSnapshot {
    var group = group
    let ids = Set(group.tabs.map(\.id))
    let other = window.split?.otherSelectedID
    group.selectedID = [window.selectedID, other].compactMap(\.self).first(where: ids.contains)
    let isPageSession = page == .chat(sessionID: sessionID)
    group.closed = window.closed.filter { tab in
      tab.content.sessionID.map { $0 == sessionID } ?? isPageSession
    }
    if let split = window.split {
      let trailing = split.trailingIDs.filter(ids.contains)
      if !trailing.isEmpty, trailing.count < ids.count {
        group.split = TabSplitSnapshot(
          trailingIDs: trailing, focused: split.focused,
          otherSelectedID: other.flatMap { ids.contains($0) ? $0 : nil },
          fraction: split.fraction)
      }
    }
    return group
  }
}
