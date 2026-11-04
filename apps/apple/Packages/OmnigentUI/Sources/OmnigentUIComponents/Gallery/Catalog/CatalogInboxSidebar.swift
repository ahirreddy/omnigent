import SwiftUI

/// Inbox: the triage list and its rows.
enum InboxCatalog {
  static var entries: [CatalogEntry] {
    [
      .component(
        .inbox, "inbox", "Inbox",
        summary: "The triage list: requests needing you, updates and read state.",
        systemImage: "tray", canvas: .fixed(width: 780, height: 720),
        keywords: ["triage", "needs you", "j k e"],
        states: [
          inbox("triage", "Three requests, two sessions", InboxTriageSamples.state),
          inbox("approvals", "Pending approvals", PreviewData.approvalsInbox),
          inbox("all-read", "All read", InboxSamples.allRead),
          inbox("empty", "Empty", InboxViewState(items: [], now: PreviewData.now)),
        ],
        live: { _ in AnyView(NavigationStack { InboxTriagePlayground() }) }),
      .component(
        .inbox, "row", "Inbox Row",
        summary: "One Inbox item: a request, a question or an update, in each phase.",
        systemImage: "tray.and.arrow.down", canvas: .column(width: 720),
        keywords: ["row", "pinned", "unread", "failed"],
        states: InboxSamples.rows.map { row in
          CatalogState(row.id, row.title) { InboxRowSample(item: row.value) }
        }),
    ]
  }

  private static func inbox(_ id: String, _ title: String, _ state: InboxViewState)
    -> CatalogState
  {
    CatalogState(id, title) {
      NavigationStack { InboxView(state: state, actions: CatalogActions.inbox) }
    }
  }
}

enum InboxSamples {
  static var allRead: InboxViewState {
    var state = PreviewData.inbox
    for index in state.items.indices {
      state.items[index].isUnread = false
      state.items[index].phase = .answered(summary: "Approved")
    }
    state.needsYouCount = 0
    return state
  }

  static var rows: [CatalogSampleItem<InboxItem>] {
    let items = InboxTriageSamples.state.items
    var failed = items[0]
    failed.phase = .failed(message: "The host is offline. Reconnect and try again.")
    var answered = items[0]
    answered.phase = .answered(summary: "Approved")
    answered.isUnread = false
    var long = items[1]
    long.preview = CatalogSamples.longText
    long.sessionTitle = "A session with a very long title that has to truncate in the Inbox row"
    return [
      CatalogSampleItem("request", "Request needing you", items[0]),
      CatalogSampleItem("read", "Read update", items[1]),
      CatalogSampleItem("question", "Question", items[2]),
      CatalogSampleItem("pinned", "Pinned update", items[3]),
      CatalogSampleItem("failed", "Response failed", failed),
      CatalogSampleItem("answered", "Answered", answered),
      CatalogSampleItem("long", "Long text", long),
    ]
  }
}

private struct InboxRowSample: View {
  let item: InboxItem
  @State private var isExpanded = false
  @State private var reply = ""

  var body: some View {
    CatalogStack {
      InboxRow(
        item: item, now: PreviewData.now, actions: CatalogActions.inbox, isSelected: false,
        select: {}, isExpanded: $isExpanded, reply: $reply)
      InboxRow(
        item: item, now: PreviewData.now, actions: CatalogActions.inbox, isSelected: true,
        select: {}, isExpanded: .constant(true), reply: .constant("On it"))
    }
  }
}

/// Session list: the sidebar and its rows.
enum SessionListCatalog {
  static var entries: [CatalogEntry] {
    [
      .component(
        .sessionList, "sidebar", "Sidebar",
        summary: "Sessions grouped by Needs you, Running and date, with filters and projects.",
        systemImage: "sidebar.left", canvas: .fixed(width: 300, height: 780),
        keywords: ["sessions", "filter", "projects", "undo", "loading"],
        states: [
          sidebar("loaded", "Loaded", PreviewData.sidebar),
          sidebar("needs-you", "Waiting on you", PreviewData.approvalsSidebar),
          sidebar("loading", "Loading", SidebarSamples.loading),
          sidebar("failed", "Refresh failed", SidebarSamples.failed),
          sidebar("empty", "No sessions", SidebarSamples.empty),
          sidebar("undo", "Undo banner", SidebarSamples.undo),
          sidebar("filtered", "Quick filter", SidebarSamples.filtered),
        ]),
      .component(
        .sessionList, "row", "Session Row",
        summary: "One session: needs-you capsule, running, failed, unread, pinned and read only.",
        systemImage: "list.bullet", canvas: .column(width: 300),
        keywords: ["row", "pinned", "unread"],
        states: [CatalogState("all", "Every status") { SessionRowSample() }]),
    ]
  }

  private static func sidebar(_ id: String, _ title: String, _ state: SidebarViewState)
    -> CatalogState
  {
    CatalogState(id, title) { SidebarSample(state: state) }
  }
}

enum SidebarSamples {
  static var loading: SidebarViewState {
    var state = PreviewData.sidebar
    state.list.sessions = []
    state.list.phase = .loading
    return state
  }

  static var failed: SidebarViewState {
    var state = PreviewData.sidebar
    state.list.phase = .failed(message: "Could not refresh sessions: the server returned 503.")
    return state
  }

  static var empty: SidebarViewState {
    var state = PreviewData.sidebar
    state.list.sessions = []
    state.projects = []
    state.list.filterCounts = [:]
    state.inboxCount = 0
    return state
  }

  static var undo: SidebarViewState {
    var state = PreviewData.sidebar
    state.undo = UndoBanner(id: "undo", kind: .archived(count: 2))
    return state
  }

  static var filtered: SidebarViewState {
    var state = PreviewData.sidebar
    state.quickFilter = .needsResponse
    return state
  }
}

private struct SidebarSample: View {
  let state: SidebarViewState
  @State private var selection: SidebarDestination? = .session(PreviewData.sessionID)
  @State private var search = ""

  var body: some View {
    NavigationStack {
      SidebarView(
        state: state, selection: $selection, searchText: $search, actions: CatalogActions.sidebar)
    }
  }
}

private struct SessionRowSample: View {
  private let list = PreviewData.sessionList

  var body: some View {
    VStack(spacing: 0) {
      ForEach(list.sessions) { session in
        SessionRow(
          session: session, info: PreviewData.rowInfo[session.id] ?? SessionRowInfo(),
          isUnread: list.unreadIds.contains(session.id),
          attention: list.attentionCounts[session.id] ?? 0,
          details: SessionDisplayOptions().details, now: PreviewData.now,
          menu: SessionRowMenu(
            session: session, isUnread: false, isShared: false, pinLimitReached: false,
            projects: [],
            actions: CatalogActions.sidebar.sessions, rename: {}, confirmDelete: {},
            confirmLeave: {})
        )
        .padding(.horizontal, Theme.Spacing.small)
        .sidebarSelection(session.id == PreviewData.sessionID)
      }
    }
    .padding(.vertical, Theme.Spacing.small)
    .themeSidebar()
  }
}

/// Inspector: the session header, plan, facts, workspace tabs and the share and fork sheets.
enum InspectorCatalog {
  static var entries: [CatalogEntry] {
    [
      .component(
        .inspector, "header", "Session Header",
        summary: "Title, status line, usage and viewers over the transcript.",
        systemImage: "rectangle.topthird.inset.filled", canvas: .column(width: 760),
        keywords: ["status", "usage", "viewers"],
        states: [
          header("running", "Running", PreviewData.shellConversation),
          header("needs-you", "Needs you", TranscriptSamples.approvals),
          header("failed", "Failed", PreviewData.failedConversation),
          header("empty", "New", PreviewData.emptyConversation),
        ]),
      .component(
        .inspector, "plan", "Plan Accordion",
        summary: "The agent's todo list with progress.",
        systemImage: "checklist.checked", canvas: .column(width: 340),
        keywords: ["todos", "progress"],
        states: [
          CatalogState("plan", "Plan") {
            CatalogStack {
              if let todos = PreviewData.shellConversation.section("todos") {
                PlanAccordion(section: todos)
              }
            }
          }
        ]),
      .component(
        .inspector, "facts", "Session Facts",
        summary: "The Info panel: status, permissions, usage, sandbox and MCP sections.",
        systemImage: "info.circle", canvas: .fixed(width: 340, height: 1_000),
        keywords: ["info", "usage", "sandbox"],
        states: [
          CatalogState("facts", "Facts") {
            SessionInspectorView(
              state: PreviewData.conversation, actions: GalleryActions.conversation)
          }
        ]),
      .component(
        .inspector, "workspace", "Workspace Panel",
        summary: "The right panel's tabs with built-in fallbacks for files, changes and terminals.",
        systemImage: "sidebar.right", canvas: .fixed(width: 340, height: 720),
        keywords: ["files", "changes", "pull requests", "agents", "terminals"],
        states: InspectorTab.allCases.map { tab in
          CatalogState(tab.rawValue, tab.title) {
            WorkspaceInspector(
              state: PreviewData.subagentConversation, actions: GalleryActions.conversation,
              slots: WorkspaceSlots(), tab: .constant(tab))
          }
        }),
      .component(
        .inspector, "share", "Share and Fork",
        summary: "The share sheet and the fork sheet.",
        systemImage: "square.and.arrow.up", canvas: .fixed(width: 520, height: 620),
        keywords: ["share", "fork", "permissions"],
        states: [
          CatalogState("share", "Share") {
            ShareSheet(state: PreviewData.share, actions: ShareActions(), done: {})
          },
          CatalogState("share-error", "Share failed") {
            ShareSheet(state: InspectorSamples.shareError, actions: ShareActions(), done: {})
          },
          CatalogState("fork", "Fork") {
            ForkSheet(
              state: PreviewData.fork, actions: ForkActions(fork: { _, _, _ in }, cancel: {}))
          },
        ]),
    ]
  }

  private static func header(_ id: String, _ title: String, _ state: ConversationViewState)
    -> CatalogState
  {
    CatalogState(id, title) { CatalogStack { SessionHeaderView(state: state) } }
  }
}

enum InspectorSamples {
  static var shareError: ShareViewState {
    var state = PreviewData.share
    state.errorMessage = "Could not update sharing: you need to be the owner."
    return state
  }
}
