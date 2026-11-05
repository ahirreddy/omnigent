import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The sidebar's view state, rebuilt only when what it reads changes.
///
/// The window's shell redraws for tab, selection and conversation changes too, and building the
/// state walks every session through the core (filtering, project members, each row's details).
/// With hundreds of sessions that ran on each of those redraws. Unchanged list values keep their
/// storage, so comparing the inputs is mostly identity checks.
@MainActor
final class SidebarStateMemo {
  private struct Inputs: Equatable {
    var sessions: [String: OmnigentCoreFFI.SessionSummary]
    var visible: [OmnigentCoreFFI.SessionSummary]
    var attention: [String: SessionAttention]
    var totals: AttentionTotals
    var unread: Set<String>
    var filter: OmnigentCoreFFI.SessionFilter
    var projects: [ProjectSummary]
    var viewerID: String?
    var environments: [String: SessionEnvironment]
    var drafts: Set<String>
    var phase: SessionListPhase
    var display: SessionDisplayOptions
    var server: ConnectedServer?
    var servers: [ServerChoice]
  }

  private var inputs: Inputs?
  private var cached: SidebarViewState?
  /// How many times the state was built, for tests.
  private(set) var builds = 0

  /// ``SidebarAdapter/state(list:display:server:servers:)``, reused while its inputs are equal.
  func state(
    list: SessionListStore, display: SessionDisplayOptions, server: ConnectedServer?,
    servers: [ServerChoice] = []
  ) -> SidebarViewState {
    let current = Inputs(
      sessions: list.sessionsByID, visible: list.visible, attention: list.attentionByID,
      totals: list.attentionTotals, unread: list.unreadIDs, filter: list.filter,
      projects: list.projects, viewerID: list.viewerID, environments: list.hostEnvironments,
      drafts: list.draftSessionIDs, phase: SidebarAdapter.phase(list), display: display,
      server: server, servers: servers)
    if let cached, current == inputs { return cached }
    let state = SidebarAdapter.state(list: list, display: display, server: server, servers: servers)
    inputs = current
    cached = state
    builds += 1
    return state
  }
}
