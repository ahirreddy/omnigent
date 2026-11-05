/// The right panel's tabs and their labels with counts ("Changes (3)", "Agents (1/2)"), shared by
/// the panel's tab bar and the compact header menu that lists each tab.
struct InspectorTabLabels {
  let state: ConversationViewState
  let slots: WorkspaceSlots

  /// The tabs the panel shows, in order.
  var tabs: [InspectorTab] { InspectorTab.shown(hasSearch: slots.search != nil) }

  /// The tab's title with its count, when it has one.
  func label(for tab: InspectorTab) -> String {
    switch tab {
    case .changes where changedCount > 0: "Changes (\(changedCount))"
    case .pullRequests where pullRequestCount > 0: "Pull Requests (\(pullRequestCount))"
    case .agents where !children.isEmpty:
      "Agents (\(children.filter { $0.summary.lowercased() == "running" }.count)/\(children.count))"
    default: tab.title
    }
  }

  private var changedCount: Int {
    state.sections.filter { $0.id.hasPrefix("files-") }
      .reduce(0) { $0 + SectionReading.changedFiles($1).count }
  }

  private var children: [EventSection] { state.sections.filter { $0.id.hasPrefix("child-") } }

  private var pullRequestCount: Int {
    if case .loaded(let pullRequests, _) = slots.pullRequests { return pullRequests.count }
    return slots.pullRequests == nil ? state.pullRequests.count : 0
  }
}
