#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Conversation chrome", .serialized)
  @MainActor
  struct TranscriptChromeTests {
    private let session = SessionSummary(id: "s", title: "Old title")
    private let projects = [
      SessionProject(id: "p", name: "Alpha", sessionIds: [], icon: "🚀"),
      SessionProject(id: "q", name: "Beta", sessionIds: []),
    ]

    init() {
      SystemSideEffects.reset()
    }

    @Test("The project tag moves the session, skips its own project and can remove it")
    func projectTag() throws {
      var moved: [String?] = []
      let filed = transcriptScreen(
        HeaderProjectTag(
          session: session, context: SessionMenuContext(projects: projects, projectID: "p"),
          move: { _, project in moved.append(project?.id) }))
      defer { filed.close() }
      #expect(try filed.shows("Alpha"))
      let frame = try #require(filed.controlFrames.first)
      let menu = try filed.openMenu(CGPoint(x: frame.midX, y: frame.midY))
      #expect(titles(of: menu) == ["Alpha", "Beta", "Remove from Project"])
      #expect(menu.items.first { $0.title == "Alpha" }?.isEnabled == false)
      try filed.choose("Beta", in: menu)
      try filed.choose("Remove from Project", in: menu)
      #expect(moved == ["q", nil])

      let unfiled = transcriptScreen(
        HeaderProjectTag(
          session: session, context: SessionMenuContext(projects: projects), move: { _, _ in }))
      defer { unfiled.close() }
      #expect(try unfiled.shows("Add to project"))

      let noIcon = transcriptScreen(
        HeaderProjectTag(
          session: session, context: SessionMenuContext(projects: projects, projectID: "q"),
          move: { _, _ in }))
      defer { noIcon.close() }
      #expect(try noIcon.shows("Beta"))
    }

    @Test("The origin bar names the relation and opens that session, titled or not")
    func originBar() throws {
      let relations: [(SessionOriginBar.Relation, String)] = [
        (.createdBy, "Created by"), (.subagentOf, "Sub-agent of"), (.sideChatOf, "Side chat of"),
      ]
      for (relation, label) in relations {
        var opened: [String] = []
        let bar = transcriptScreen(
          SessionOriginBar(
            relation: relation, origin: CreatingSession(id: "o", title: "Parent"),
            open: { opened.append($0) }))
        defer { bar.close() }
        #expect(try bar.shows(label))
        #expect(try bar.shows("Parent"))
        #expect(!relation.help.isEmpty && !relation.identifier.isEmpty)
        try bar.clickControl(at: 0)
        #expect(opened == ["o"])
      }
      let untitled = transcriptScreen(
        SessionOriginBar(
          relation: .createdBy, origin: CreatingSession(id: "o", title: nil), open: { _ in }))
      defer { untitled.close() }
      #expect(try untitled.shows("another session"))
    }

    private struct Dialogs: View {
      let actions: SessionListActions
      var branch: String?
      let session: SessionSummary
      @State private var renaming: SessionSummary?
      @State private var renameText = ""
      @State private var confirmingDelete: SessionSummary?
      @State private var confirmingLeave: SessionSummary?
      @State private var confirmingStop: SessionSummary?

      init(actions: SessionListActions, branch: String? = nil, session: SessionSummary) {
        self.actions = actions
        self.branch = branch
        self.session = session
      }

      var body: some View {
        VStack {
          Button("Rename") {
            renameText = "  New title  "
            renaming = session
          }
          Button("Blank") {
            renameText = "   "
            renaming = session
          }
          Button("Delete") { confirmingDelete = session }
          Button("Leave") { confirmingLeave = session }
          Button("Stop") { confirmingStop = session }
        }
        .modifier(
          SessionMenuDialogs(
            renaming: $renaming, renameText: $renameText, confirmingDelete: $confirmingDelete,
            confirmingLeave: $confirmingLeave, confirmingStop: $confirmingStop, actions: actions,
            branch: branch))
      }
    }

    @Test("Delete and Leave ask first, and do it on confirmation")
    func confirmations() throws {
      let log = HostLog()
      var actions = SessionListActions()
      actions.delete = { log.add("delete \($0.id)") }
      actions.leave = { log.add("leave \($0.id)") }
      actions.stop = { log.add("stop \($0.id)") }
      let screen = transcriptScreen(Dialogs(actions: actions, session: session))
      defer { screen.close() }
      try screen.clickControl(at: 2)
      #expect(
        SystemSideEffects.record.alertMessages.contains { $0.contains("Delete this session?") })
      #expect(log.entries == ["delete s"])
      try screen.clickControl(at: 3)
      #expect(
        SystemSideEffects.record.alertMessages.contains { $0.contains("Leave this session?") })
      #expect(log.entries == ["delete s", "leave s"])
      try screen.clickControl(at: 4)
      #expect(log.entries == ["delete s", "leave s", "stop s"])
    }

    @Test("A session with a branch offers to delete it too, in a sheet")
    func deleteWithBranch() throws {
      var deleted: [Bool] = []
      var actions = SessionListActions()
      actions.deleteWithBranch = { _, withBranch in deleted.append(withBranch) }
      let screen = transcriptScreen(
        Dialogs(actions: actions, branch: "feature/x", session: session))
      defer { screen.close() }
      try screen.clickControl(at: 2)
      #expect(screen.window.attachedSheet != nil)
      #expect(try screen.shows("feature/x"))
      // A click doesn't reach a default button's AppKit view here; Return is its other way in.
      try screen.press(keyCode: 36, characters: "\r")
      #expect(deleted.count == 1)
      #expect(screen.window.attachedSheet == nil)
    }

    @Test("Rename saves the trimmed title")
    func rename() throws {
      var renamed: [String] = []
      var actions = SessionListActions()
      actions.rename = { _, title in renamed.append(title) }
      let screen = transcriptScreen(Dialogs(actions: actions, session: session))
      defer { screen.close() }
      try screen.clickControl(at: 0)
      #expect(renamed == ["New title"])
    }

    @Test("The view mode switch changes mode, and the compact menu lists both")
    func viewModes() throws {
      #expect(SessionViewMode.chat.title == "Chat")
      #expect(SessionViewMode.terminal.title == "Terminal")
      #expect(SessionViewMode.chat.systemImage != SessionViewMode.terminal.systemImage)

      struct Host: View {
        let changed: (SessionViewMode) -> Void
        @State private var mode = SessionViewMode.chat

        init(changed: @escaping (SessionViewMode) -> Void) {
          self.changed = changed
        }

        var body: some View {
          VStack {
            ViewModePicker(mode: $mode, status: .ready)
            CompactViewModeItems(mode: $mode)
          }
          .onChange(of: mode) { changed(mode) }
        }
      }
      var changes: [SessionViewMode] = []
      let screen = transcriptScreen(Host(changed: { changes.append($0) }))
      defer { screen.close() }
      let picker = try #require(screen.controlFrames.first)
      try screen.click(CGPoint(x: picker.maxX - 8, y: picker.midY))
      #expect(changes == [.terminal])
    }

    @Test("The compact panel menu lists each tab, opening the panel on it")
    func compactPanelItems() throws {
      var shown: [InspectorTab] = []
      let labels = InspectorTabLabels(state: PreviewData.conversation, slots: WorkspaceSlots())
      let screen = transcriptScreen(
        VStack { CompactPanelItems(labels: labels) { shown.append($0) } })
      defer { screen.close() }
      #expect(try screen.shows(labels.label(for: try #require(labels.tabs.first))))
      try screen.clickControl(at: 0)
      #expect(shown == [try #require(labels.tabs.first)])
    }

    @Test("The session menu button opens its actions, and Share's label can drop its title")
    func sessionMenuButton() throws {
      var ran = 0
      let screen = transcriptScreen(
        VStack {
          SessionActionsButton { Button("Pin") { ran += 1 } }
          Label("Share", systemImage: "person.badge.plus")
            .labelStyle(HeaderShareLabelStyle(isCompact: true))
          Label("Wide", systemImage: "person.badge.plus")
            .labelStyle(HeaderShareLabelStyle(isCompact: false))
          BarHitShield().frame(height: 10)
        })
      defer { screen.close() }
      #expect(try !screen.shows("Share"))
      #expect(try screen.shows("Wide"))
      let frame = try #require(screen.controlFrames.first)
      let menu = try screen.openMenu(CGPoint(x: frame.midX, y: frame.midY))
      try screen.choose("Pin", in: menu)
      #expect(ran == 1)
    }

    private func replyHost(
      reply: @escaping @MainActor (String) -> Void, ask: (@MainActor (String) -> Void)?
    )
      -> OffscreenWindow<AnyView>
    {
      transcriptScreen(
        ScrollView {
          VStack(alignment: .leading) {
            Text("Spacer").frame(height: 60)
            Text("Selectable words here").textSelection(.enabled).padding(.leading, 20)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .transcriptSelectionPopup(reply: reply, ask: ask))
    }

    /// The popup reads the selection when the event monitor sees an event, which only
    /// `NSApp.sendEvent` delivers; a key up reaches nothing else here.
    private func announceSelection(_ screen: OffscreenWindow<AnyView>) async throws {
      let event = NSEvent.keyEvent(
        with: .keyUp, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: screen.window.windowNumber,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0)
      NSApp.sendEvent(try #require(event))
      try await letTasksRun(screen)
    }

    @Test("Selecting text offers Reply and Ask, each acting on the selection and clearing it")
    func selectionPopup() async throws {
      let log = HostLog()
      let screen = replyHost(reply: { log.add("reply \($0)") }, ask: { log.add("ask \($0)") })
      defer { screen.close() }
      #expect(try !screen.shows("Reply"))
      try screen.click(CGPoint(x: 30, y: 75), clickCount: 2)
      try await announceSelection(screen)
      #expect(try screen.shows("Reply"))
      #expect(try screen.shows("Ask in side chat"))
      try screen.clickControl(at: 0)
      #expect(log.entries.first?.hasPrefix("reply ") == true)
      try await letTasksRun(screen)
      #expect(try !screen.shows("Ask in side chat"))
      #expect(try screen.shows("Selectable words here"))
    }

    @Test("Without a side chat only Reply shows, and without Reply nothing does")
    func selectionPopupHosts() async throws {
      let replyOnly = replyHost(reply: { _ in }, ask: nil)
      defer { replyOnly.close() }
      try replyOnly.click(CGPoint(x: 30, y: 75), clickCount: 2)
      try await announceSelection(replyOnly)
      #expect(try replyOnly.shows("Reply"))
      #expect(try !replyOnly.shows("Ask in side chat"))

      // A click elsewhere ends the selection, and the popup goes with it.
      replyOnly.window.makeFirstResponder(nil)
      try await announceSelection(replyOnly)
      #expect(try !replyOnly.shows("Reply"))
      #expect(try replyOnly.shows("Selectable words here"))
    }
  }
#endif
