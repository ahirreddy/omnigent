#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Inspector: the changes and agents panels", .serialized)
  @MainActor
  struct InspectorPanelsTests {
    private func window(_ view: some View) -> OffscreenWindow<AnyView> {
      OffscreenWindow(AnyView(view.frame(width: 400, height: 500)), width: 400, height: 500)
    }

    @Test("No changed files says so")
    func noChanges() throws {
      let state = ConversationViewState(header: SessionHeader(id: "s", title: "S"))
      let screen = window(ChangedFilesFallback(state: state))
      defer { screen.close() }
      #expect(try screen.shows("No changes"))
    }

    @Test("Changed files across sections are listed with letter and folder")
    func changes() throws {
      let state = ConversationViewState(
        header: SessionHeader(id: "s", title: "S"),
        sections: [
          EventSection(
            id: "files-a", title: "", summary: "",
            details: [
              DetailSection(id: "1", title: "a/new.swift", text: "added"),
              DetailSection(id: "2", title: "a/gone.swift", text: "deleted"),
            ]),
          EventSection(
            id: "files-b", title: "", summary: "",
            details: [DetailSection(id: "3", title: "b/edit.swift", text: "modified")]),
        ])
      let screen = window(ChangedFilesFallback(state: state))
      defer { screen.close() }
      for text in ["new.swift", "gone.swift", "edit.swift", "A", "D", "M", "a", "b"] {
        #expect(try screen.shows(text), "\(text)")
      }
    }

    @Test("With no sub-agents the main agent shows and a hint says what will appear")
    func noAgents() throws {
      var state = ConversationViewState(header: SessionHeader(id: "s", title: "S"))
      state.agentInfo = AgentInfo(name: "Coder")
      let screen = window(AgentsPanel(state: state, open: nil))
      defer { screen.close() }
      #expect(try screen.shows("Coder"))
      #expect(try screen.shows("Sub-agents this session starts appear here."))
      let unnamed = window(
        AgentsPanel(
          state: ConversationViewState(header: SessionHeader(id: "s", title: "S")), open: nil))
      defer { unnamed.close() }
      #expect(try unnamed.shows("main"))
    }

    @Test("A child session offers its parent")
    func parent() throws {
      var opened: [String] = []
      let settings = SessionSettings(parentId: "parent")
      let state = ConversationViewState(
        header: SessionHeader(id: "s", title: "S", settings: settings))
      let screen = window(AgentsPanel(state: state) { opened.append($0) })
      defer { screen.close() }
      #expect(try screen.shows("Parent session"))
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(opened == ["parent"])
    }

    @Test("A session that's its own parent shows as the main agent")
    func ownParent() throws {
      let state = ConversationViewState(
        header: SessionHeader(id: "s", title: "S", settings: SessionSettings(parentId: "s")))
      let screen = window(AgentsPanel(state: state, open: nil))
      defer { screen.close() }
      #expect(try !screen.shows("Parent session"))
    }

    @Test("Each child opens, with its status and activity shown")
    func children() throws {
      var opened: [String] = []
      let screen = window(
        AgentsPanel(state: PreviewData.subagentConversation) { opened.append($0) })
      defer { screen.close() }
      let group = try #require(SubagentGroup(state: PreviewData.subagentConversation))
      for child in group.children {
        #expect(try screen.shows(child.title), "\(child.title)")
      }
      #expect(try !screen.shows("Sub-agents this session starts appear here."))
      let controls = screen.controlFrames.count
      try screen.clickControl(at: controls - 1)
      #expect(opened == [group.children[group.children.count - 1].id])
    }

    @Test("Without a way to open sessions children are disabled")
    func childrenDisabled() throws {
      let screen = window(AgentsPanel(state: PreviewData.subagentConversation, open: nil))
      defer { screen.close() }
      let buttons = screen.plainButtons.filter { $0.isEnabled }
      #expect(buttons.isEmpty)
    }

    private func child(_ details: [(String, String)]) -> ConversationViewState {
      ConversationViewState(
        header: SessionHeader(id: "s", title: "S"),
        sections: [
          EventSection(
            id: "child-a", title: "Child", summary: "",
            details: details.map { DetailSection(id: $0.0, title: "", text: $0.1) },
            sessionId: "child-1")
        ])
    }

    @Test("Each status draws its own mark")
    func statuses() throws {
      var pictures: Set<Data> = []
      for status in SubagentStatus.allCases where status != .starting {
        let state = child([("state", status.rawValue)])
        pictures.insert(
          try RenderSupport.picture(AgentsPanel(state: state, open: nil), width: 300, height: 120))
      }
      #expect(pictures.count == 4)
    }

    @Test("A child's line prefers its error, then activity, then goal")
    func childLine() throws {
      let screen = window(
        AgentsPanel(
          state: child([
            ("agent", "tester"), ("goal", "The goal"), ("activity", "The activity"),
            ("error", "The error"),
          ]), open: nil))
      defer { screen.close() }
      #expect(try screen.shows("tester"))
      #expect(try screen.shows("The error"))
      #expect(try !screen.shows("The activity"))
      let working = window(
        AgentsPanel(state: child([("goal", "The goal"), ("activity", "The activity")]), open: nil))
      defer { working.close() }
      #expect(try working.shows("The activity"))
      #expect(try !working.shows("The goal"))
      let starting = window(AgentsPanel(state: child([("goal", "The goal")]), open: nil))
      defer { starting.close() }
      #expect(try starting.shows("The goal"))
    }
  }

  @Suite("Inspector: the session header", .serialized)
  @MainActor
  struct InspectorHeaderTests {
    private func header(
      _ edit: (inout ConversationViewState) -> Void = { _ in }, showsTitle: Bool = true,
      width: CGFloat = 900
    ) -> OffscreenWindow<AnyView> {
      var state = ConversationViewState(header: SessionHeader(id: "s", title: "A session"))
      edit(&state)
      let view = SessionHeaderView(state: state, showsTitle: showsTitle).frame(
        width: width, height: 100)
      return OffscreenWindow(AnyView(view), width: width, height: 100)
    }

    @Test("It shows the title, project and status")
    func title() throws {
      let screen = header { $0.projectName = "Work" }
      defer { screen.close() }
      #expect(try screen.shows("A session"))
      #expect(try screen.shows("Work"))
      #expect(try screen.shows("Ready"))
    }

    @Test("Where the titlebar has the title it's left out")
    func noTitle() throws {
      let screen = header(showsTitle: false)
      defer { screen.close() }
      #expect(try !screen.shows("A session"))
      #expect(try screen.shows("Ready"))
    }

    @Test("Read-only and archived sessions say so")
    func pills() throws {
      let plain = header()
      defer { plain.close() }
      #expect(try !plain.shows("Read only"))
      #expect(try !plain.shows("Archived"))
      let screen = header {
        $0.header.readOnly = true
        $0.header.archived = true
      }
      defer { screen.close() }
      #expect(try screen.shows("Read only"))
      #expect(try screen.shows("Archived"))
    }

    @Test("Settings show the model")
    func model() throws {
      let screen = header { $0.header.settings = SessionSettings(baseModel: "opus") }
      defer { screen.close() }
      #expect(try screen.shows("opus"))
    }

    @Test("Usage shows the percent of context used")
    func usageGauge() throws {
      let screen = header {
        $0.sections = [
          EventSection(
            id: "usage", title: "", summary: "",
            details: [
              DetailSection(id: "context_tokens", title: "", text: "250"),
              DetailSection(id: "context_window", title: "", text: "1000"),
            ])
        ]
      }
      defer { screen.close() }
      #expect(try screen.shows("25%"))
    }

    private func viewers(_ count: Int) -> EventSection {
      EventSection(
        id: "presence", title: "", summary: "",
        details: (0..<count).map {
          DetailSection(id: "\($0)", title: "Viewer \($0)", text: "Active")
        })
    }

    @Test("Past four viewers the rest are counted")
    func overflowViewers() throws {
      let screen = header { $0.sections = [viewers(6)] }
      defer { screen.close() }
      #expect(try screen.shows("+2"))
      let few = header { $0.sections = [viewers(4)] }
      defer { few.close() }
      #expect(try !few.shows("+0"))
    }

    @Test("With no viewers nothing is drawn for them")
    func noViewers() throws {
      func picture(_ count: Int?) throws -> Data {
        var state = ConversationViewState(header: SessionHeader(id: "s", title: "S"))
        if let count { state.sections = [viewers(count)] }
        return try RenderSupport.picture(SessionHeaderView(state: state), width: 500, height: 60)
      }
      #expect(try picture(0) == picture(nil))
      #expect(try picture(1) != picture(nil))
    }

    @Test("Too narrow for one line it stacks, still showing everything")
    func narrow() throws {
      let screen = header(
        {
          $0.header.settings = SessionSettings(baseModel: "a-very-long-model-name-that-takes-room")
          $0.header.readOnly = true
          $0.header.archived = true
          $0.projectName = "Project"
        }, width: 320)
      defer { screen.close() }
      #expect(try screen.shows("A session"))
      #expect(try screen.shows("a-very-long-model-name-that-takes-room"))
    }

    @Test("A compact window pads less")
    func compact() throws {
      func picture(_ layout: LayoutWidth) throws -> Data {
        let rendered = try RenderSupport.render(
          SessionHeaderView(
            state: ConversationViewState(header: SessionHeader(id: "s", title: "S"))),
          width: 500, height: 60, scheme: .light, layout: layout)
        return try #require(rendered.image.tiffRepresentation)
      }
      #expect(try picture(.compact) != picture(.regular))
    }
  }
#endif
