#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Sidebar: project sheets, header and markers", .serialized)
  @MainActor
  struct SessionListProjectSheetTests {
    private let work = SessionProject(
      id: "p1", name: "Work", sessionIds: ["beta"], icon: "\u{1F680}")
    private let home = SessionProject(id: "p2", name: "Home", sessionIds: [])
    private let workRow = 8

    private func spy() -> SidebarSpy {
      var state = SidebarFixture.state
      state.projects = [work, home]
      state.projectSort = .alphabetical
      return SidebarSpy(state)
    }

    private func expanded() -> String? {
      UserDefaults.standard.string(forKey: SidebarNavigationOrder.expandedProjectsKey)
    }

    @Test("a folder or section's marker is its sessions' strongest state")
    func strongest() {
      func summary(_ id: String, _ attention: SessionAttentionState) -> SessionSummary {
        SessionSummary(id: id, title: id, attention: attention)
      }
      func marker(
        _ sessions: [SessionSummary], unread: Set<String> = [], counts: [String: Int] = [:],
        info: [String: SessionRowInfo] = [:]
      ) -> SidebarMarker? {
        SidebarMarker.strongest(
          sessions,
          list: SessionListViewState(
            sessions: sessions, unreadIds: unread, attentionCounts: counts),
          rowInfo: info)
      }
      let needs = summary("n", .needsYou)
      let working = summary("w", .working)
      let failed = summary("f", .failed)
      let idle = summary("i", .idle)
      #expect(marker([idle]) == nil)
      #expect(marker([]) == nil)
      #expect(marker([summary("u", .unread)]) == .unread)
      #expect(marker([idle], unread: ["i"]) == .unread)
      #expect(marker([idle], info: ["i": SessionRowInfo(isDisconnected: true)]) == .disconnected)
      #expect(marker([failed, idle]) == .failed)
      #expect(marker([needs, working, failed]) == .needsYou(requests: 1))
      #expect(marker([needs, summary("m", .needsYou)], counts: ["m": 3]) == .needsYou(requests: 4))
      #expect(marker([working, idle]) == .working)
    }

    @Test("every marker draws differently")
    func markerViews() throws {
      var pictures: Set<Data> = []
      let markers: [SidebarMarker] = [
        .needsYou(requests: 1), .needsYou(requests: 3), .failed, .disconnected, .unread,
      ]
      for marker in markers {
        let rendered = try RenderSupport.render(
          SidebarMarkerView(marker: marker), width: 120, height: 30, scheme: .light,
          layout: .regular)
        pictures.insert(try #require(rendered.image.representation(using: .png, properties: [:])))
      }
      #expect(pictures.count == markers.count)
      _ = try RenderSupport.render(
        SidebarMarkerView(marker: .working), width: 120, height: 30, scheme: .light,
        layout: .regular)
    }

    @Test("the Projects header's menu offers what would do something")
    func headerMenu() throws {
      let spy = spy()
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      // Rows: 7 is the Projects header: New project is a button, the rest a menu.
      let popUp = try #require(try screen.popUps(inRow: 7).first)
      let menu = try screen.openMenu(popUp)
      #expect(menu.item(named: "Expand all") != nil)
      #expect(menu.item(named: "Collapse all") == nil)
      #expect(menu.item(named: "Select sessions") != nil)
      try screen.choose("Expand all", in: menu)
      #expect(expanded() == "p1\np2")
      let open = try screen.openMenu(try #require(try screen.popUps(inRow: 7).first))
      #expect(open.item(named: "Expand all") == nil)
      try screen.choose("Collapse all", in: open)
      #expect(expanded()?.isEmpty == true)
      let sortChoices = try screen.openMenu(try #require(try screen.popUps(inRow: 7).first))
      let other = try #require(ProjectSort.allCases.first { $0 != .alphabetical })
      try screen.choose(other.title, in: sortChoices)
      #expect(spy.calls.contains("project sort \(other)"))
    }

    @Test("Select sessions from the Projects menu turns on selection")
    func headerSelect() throws {
      let spy = spy()
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      let menu = try screen.openMenu(try #require(try screen.popUps(inRow: 7).first))
      try screen.choose("Select sessions", in: menu)
      // Selecting hides the Projects header's buttons.
      #expect(try screen.popUps(inRow: 7).isEmpty)
    }

    /// The name sheet with its name already typed: a sheet's field editor takes no test input.
    private struct NameHost: View {
      let spy: SidebarSpy
      @State private var prompt: ProjectPrompt?
      @State private var name: String
      @State private var deleting: SessionProject?

      init(spy: SidebarSpy, prompt: ProjectPrompt, name: String) {
        self.spy = spy
        _prompt = State(initialValue: prompt)
        _name = State(initialValue: name)
      }

      var body: some View {
        Color.clear.modifier(
          ProjectDialogs(
            prompt: $prompt, name: $name, confirmingDelete: $deleting, actions: spy.actions))
      }
    }

    @Test("New project opens the sheet, with Create off until there's a name")
    func newProjectButton() throws {
      let spy = spy()
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      try screen.click(try #require(try screen.plainButtons(inRow: 7).first))
      #expect(screen.window.attachedSheet != nil)
      let fields = screen.allViews.compactMap { $0 as? NSTextField }.filter(\.isEditable)
      #expect(fields.count == 2)
      let controlsWithoutCreate = screen.controlFrames.count
      try screen.click(try #require(fields.first))
      try screen.type(" Side ")
      #expect(screen.controlFrames.count == controlsWithoutCreate + 1)
      try screen.click(try #require(fields.last))
      try screen.type("\u{1F680}\u{1F4A1}")
      let create = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: create.midX, y: create.midY))
      // The name is trimmed and the icon keeps the latest emoji.
      #expect(spy.calls == ["create Side \u{1F4A1} -"])
      #expect(screen.window.attachedSheet == nil)
    }

    @Test("Create trims the name, and files the session it was opened from")
    func createSubmits() throws {
      let spy = spy()
      let screen = OffscreenWindow(
        NameHost(spy: spy, prompt: .create(moving: SidebarFixture.beta), name: "  Side "),
        width: 500, height: 500)
      defer { screen.close() }
      let create = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: create.midX, y: create.midY))
      #expect(spy.calls == ["create Side - beta"])
      #expect(screen.window.attachedSheet == nil)
    }

    @Test("a name past the server's limit can't be created")
    func tooLong() throws {
      let spy = spy()
      let screen = OffscreenWindow(
        NameHost(spy: spy, prompt: .create(moving: nil), name: String(repeating: "x", count: 121)),
        width: 500, height: 500)
      defer { screen.close() }
      // Create is off, so the last control is Cancel.
      let cancel = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: cancel.midX, y: cancel.midY))
      #expect(spy.calls.isEmpty)
    }

    @Test("Rename project starts from the name and icon, and Remove icon clears it")
    func renameSheet() throws {
      let spy = spy()
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      try screen.choose(
        "Rename project\u{2026}", in: try #require(try screen.menu(ofRow: workRow)))
      let fields = screen.allViews.compactMap { $0 as? NSTextField }.filter(\.isEditable)
      #expect(fields.first?.stringValue == "Work")
      #expect(fields.last?.stringValue == "\u{1F680}")
      let remove = try #require(screen.plainButtons.first)
      try screen.click(remove)
      #expect(fields.last?.stringValue.isEmpty == true)
      let rename = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: rename.midX, y: rename.midY))
      #expect(spy.calls == ["rename project p1 Work -"])
    }

    @Test("Cancel leaves the name sheet with nothing done")
    func cancelSheet() throws {
      let spy = spy()
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      try screen.choose(
        "Rename project\u{2026}", in: try #require(try screen.menu(ofRow: workRow)))
      let frames = screen.controlFrames
      let cancel = try #require(frames.dropLast().last)
      try screen.click(CGPoint(x: cancel.midX, y: cancel.midY))
      #expect(spy.calls.isEmpty)
      #expect(screen.window.attachedSheet == nil)
    }
  }
#endif
