#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The state a host holds around the right panel, and what the panel asks it to do.
  @MainActor
  @Observable
  final class WorkspaceHost {
    var tab: InspectorTab = .files
    var maximized = false
    var isPresented = true
    var selectedDocument: String?
    var calls: [String] = []

    var tabBinding: Binding<InspectorTab> {
      Binding(get: { self.tab }, set: { self.tab = $0 })
    }

    var maximizedBinding: Binding<Bool> {
      Binding(get: { self.maximized }, set: { self.maximized = $0 })
    }

    var presentedBinding: Binding<Bool> {
      Binding(get: { self.isPresented }, set: { self.isPresented = $0 })
    }

    /// Two open files, with the viewer the shown one would have.
    var documents: InspectorDocuments {
      InspectorDocuments(
        tabs: [
          InspectorDocumentTab(
            id: "one", title: "one.swift", detail: "/repo/one.swift", systemImage: "doc"),
          InspectorDocumentTab(
            id: "two", title: "two.swift", detail: "/repo/two.swift", systemImage: "doc"),
        ],
        selected: selectedDocument,
        select: { [self] in
          calls.append("select \($0)")
          selectedDocument = $0
        },
        close: { [self] in calls.append("close \($0)") },
        showPanel: { [self] in
          calls.append("show panel")
          selectedDocument = nil
        },
        content: AnyView(Text("viewer of \(selectedDocument ?? "-")")))
    }
  }

  struct WorkspacePanelHarness: View {
    let host: WorkspaceHost
    let state: ConversationViewState
    let slots: (WorkspaceHost) -> WorkspaceSlots
    var hasMaximize = true

    var body: some View {
      WorkspaceInspector(
        state: state, actions: ConversationActions(), slots: slots(host), tab: host.tabBinding,
        maximized: hasMaximize ? host.maximizedBinding : nil)
    }
  }

  @MainActor
  func workspacePanel(
    _ host: WorkspaceHost, state: ConversationViewState = .inspectorSample,
    width: CGFloat = 700, slots: @escaping (WorkspaceHost) -> WorkspaceSlots = { _ in .filled }
  ) -> OffscreenWindow<AnyView> {
    OffscreenWindow(
      AnyView(WorkspacePanelHarness(host: host, state: state, slots: slots)), width: width,
      height: 500)
  }

  @MainActor
  func slotsWithDocuments(_ host: WorkspaceHost) -> WorkspaceSlots {
    var slots = WorkspaceSlots.filled
    slots.documents = host.documents
    return slots
  }

  @Suite("Inspector: the right panel's tabs", .serialized)
  @MainActor
  struct InspectorWorkspaceTests {
    @Test("Each tab shows its content under a heading with its name")
    func clickingTabs() throws {
      let host = WorkspaceHost()
      let screen = workspacePanel(host)
      defer { screen.close() }
      let positions: [(tab: InspectorTab, position: Int)] = [
        (.changes, 1), (.agents, 3), (.search, 5), (.files, 0),
      ]
      for (tab, position) in positions {
        try screen.clickControl(at: position)
        #expect(host.tab == tab)
        #expect(try screen.shows(tab.title))
        #expect(try screen.shows("\(tab.rawValue) slot"))
      }
      #expect(try !screen.shows("agents slot"))
    }

    @Test("Without content from the app, each tab has its own fallback")
    func fallbacks() throws {
      let host = WorkspaceHost()
      let screen = workspacePanel(host, slots: { _ in WorkspaceSlots() })
      defer { screen.close() }
      #expect(try screen.shows("The session's files appear here when its host is connected."))
      // The Search tab isn't offered: Files, Changes, PRs, Agents, Info and the full screen button.
      #expect(screen.controlFrames.count == 6)
      try screen.clickControl(at: 1)
      #expect(try !screen.shows("The session's files appear here when its host is connected."))
      #expect(try screen.shows("No changes"))
      try screen.clickControl(at: 2)
      #expect(try screen.shows("Pull requests created or worked on in this session appear here."))
      try screen.clickControl(at: 3)
      #expect(try screen.shows("Sub-agents this session starts appear here."))
      try screen.clickControl(at: 4)
      #expect(try screen.shows("Status"))
    }

    @Test("A remembered Search tab shows Files on a server without search")
    func searchFallsBack() throws {
      let host = WorkspaceHost()
      host.tab = .search
      let screen = workspacePanel(
        host, slots: { _ in WorkspaceSlots(files: AnyView(Text("files slot"))) })
      defer { screen.close() }
      #expect(try screen.shows("files slot"))
      #expect(try !screen.shows("Search"))
    }

    @Test("A narrow panel shows symbols instead of titles, and they still switch tabs")
    func narrowTabs() throws {
      let host = WorkspaceHost()
      let screen = workspacePanel(host, width: 240)
      defer { screen.close() }
      // The titled bar needs 66 points for Changes; each symbol needs about 30.
      #expect(screen.controlFrames[1].width < 40)
      #expect(screen.controlFrames.allSatisfy { $0.maxX <= 240 })
      try screen.clickControl(at: 1)
      #expect(host.tab == .changes)
      #expect(try screen.shows("changes slot"))
    }

    @Test("The Pull Requests tab reads what the app loaded, and refreshes when it shows")
    func pullRequestsSlot() async throws {
      let host = WorkspaceHost()
      host.tab = .pullRequests
      let screen = workspacePanel(
        host,
        slots: { host in
          WorkspaceSlots(
            pullRequests: .loaded([], synced: false),
            refreshPullRequests: { host.calls.append("refresh") })
        })
      defer { screen.close() }
      try await Task.sleep(for: .milliseconds(30))
      screen.settle(0.05)
      #expect(host.calls == ["refresh"])
    }

    @Test("Opening a file puts its viewer in place of the tab, with no heading or selected tab")
    func documentReplacesTab() throws {
      let host = WorkspaceHost()
      host.selectedDocument = "two"
      let screen = workspacePanel(host, slots: slotsWithDocuments)
      defer { screen.close() }
      #expect(try screen.shows("viewer of two"))
      #expect(try !screen.shows("files slot"))
      // Only the tab bar's Files is left: the heading is gone.
      let filesLines = try screen.shownText().filter { $0 == "Files" }
      #expect(filesLines.count == 1)
      try screen.clickControl(at: 1)
      #expect(host.calls == ["show panel"])
      #expect(host.tab == .changes)
      #expect(host.selectedDocument == nil)
      #expect(try screen.shows("changes slot"))
    }

    @Test("Tab labels carry their counts, and only when there's something to count")
    func labels() {
      let files = EventSection(
        id: "files-1", title: "Files", summary: "",
        details: [
          DetailSection(id: "a", title: "a.swift", text: "M"),
          DetailSection(id: "b", title: "b.swift", text: "A"),
        ])
      let children = [
        EventSection(id: "child-1", title: "One", summary: "Running"),
        EventSection(id: "child-2", title: "Two", summary: "done"),
      ]
      let pullRequest = PullRequestSummary(
        id: "1", number: 1, title: "T", repo: "r", url: "https://example.test/1", status: .open)
      var state = ConversationViewState.inspectorSample
      state.sections = [files] + children
      state.pullRequests = [pullRequest]
      let fromState = InspectorTabLabels(state: state, slots: WorkspaceSlots())
      #expect(fromState.label(for: .changes) == "Changes (2)")
      #expect(fromState.label(for: .agents) == "Agents (1/2)")
      #expect(fromState.label(for: .pullRequests) == "Pull Requests (1)")
      #expect(fromState.label(for: .files) == "Files")
      #expect(fromState.tabs == [.files, .changes, .pullRequests, .agents, .info])

      let empty = InspectorTabLabels(state: .inspectorSample, slots: WorkspaceSlots())
      #expect(empty.label(for: .changes) == "Changes")
      #expect(empty.label(for: .agents) == "Agents")
      #expect(empty.label(for: .pullRequests) == "Pull Requests")

      // The app's list wins over the conversation's, and an unfinished read counts nothing.
      let loaded = InspectorTabLabels(
        state: state,
        slots: WorkspaceSlots(pullRequests: .loaded([pullRequest, pullRequest], synced: true)))
      #expect(loaded.label(for: .pullRequests) == "Pull Requests (2)")
      let loading = InspectorTabLabels(state: state, slots: WorkspaceSlots(pullRequests: .loading))
      #expect(loading.label(for: .pullRequests) == "Pull Requests")
    }

    @Test("Each tab has a name, a short name for the bar, and a symbol of its own")
    func tabNames() {
      #expect(
        InspectorTab.allCases.map(\.title) == [
          "Files", "Changes", "Pull Requests", "Agents", "Info", "Search",
        ])
      #expect(InspectorTab.pullRequests.shortTitle == "PRs")
      #expect(InspectorTab.changes.shortTitle == "Changes")
      #expect(Set(InspectorTab.allCases.map(\.systemImage)).count == InspectorTab.allCases.count)
      #expect(InspectorTab.files.id == .files)
      #expect(!InspectorTab.shown(hasSearch: false).contains(.search))
      #expect(InspectorTab.shown(hasSearch: true).last == .search)
    }
  }

  extension ConversationViewState {
    /// A conversation with nothing in it.
    static var inspectorSample: ConversationViewState {
      ConversationViewState(
        header: SessionHeader(id: "s", title: "Session", status: .idle),
        rows: [], decisions: [], sections: [])
    }
  }

  extension WorkspaceSlots {
    /// Every tab's content is a line a test can read.
    static var filled: WorkspaceSlots {
      WorkspaceSlots(
        files: AnyView(Text("files slot")), changes: AnyView(Text("changes slot")),
        search: AnyView(Text("search slot")), agents: AnyView(Text("agents slot")))
    }
  }
#endif
