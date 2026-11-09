#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Sidebar: delete and archive dialogs", .serialized)
  @MainActor
  struct SessionListDialogTests {
    private let beta = SidebarFixture.beta
    private let gamma = SidebarFixture.gamma

    private func sheet(
      _ sessions: [SessionSummary], branches: [String: String], spy: SidebarSpy
    ) -> some View {
      DeleteSessionsSheet(
        sessions: sessions, branches: branches,
        delete: { spy.calls.append("delete \($0.sorted().joined(separator: ","))") },
        cancel: { spy.calls.append("cancel") })
    }

    @Test("deleting one session without a branch has just Cancel and Delete")
    func plain() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(
        sheet([beta], branches: [:], spy: spy), width: 480, height: 300)
      defer { screen.close() }
      #expect(screen.controlFrames.count == 2)
      try screen.clickControl(at: 0)
      #expect(spy.calls == ["cancel"])
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.calls == ["cancel", "delete "])

    }

    @Test("a branch stays unless its box is checked")
    func oneBranch() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(
        sheet([beta, gamma], branches: ["beta": "feature/b"], spy: spy), width: 480, height: 400)
      defer { screen.close() }
      // One branch: no All box. Its checkbox, Cancel, Delete.
      #expect(screen.controlFrames.count == 3)
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.calls == ["delete "])
      try screen.clickControl(at: 0)
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.calls.last == "delete beta")
      try screen.clickControl(at: 0)
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.calls.last == "delete ")
    }

    @Test("All branches checks and clears them all, and follows the boxes")
    func allBranches() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(
        sheet([beta, gamma], branches: ["beta": "b", "gamma": "g"], spy: spy), width: 480,
        height: 500)
      defer { screen.close() }
      // All, two checkboxes, Cancel, Delete.
      #expect(screen.controlFrames.count == 5)
      try screen.clickControl(at: 0)
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.calls.last == "delete beta,gamma")
      try screen.clickControl(at: 1)
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.calls.last == "delete gamma")
      try screen.clickControl(at: 0)
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.calls.last == "delete beta,gamma")
      try screen.clickControl(at: 0)
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.calls.last == "delete ")
    }

    @Test("Delete on a worktree session opens the branch sheet, and only its answer deletes")
    func branchFlow() throws {
      var state = SidebarFixture.state
      state.rowInfo = ["beta": SessionRowInfo(branch: "feature/b")]
      let spy = SidebarSpy(state)
      var actions = spy.actions
      actions.sessions.deleteWithBranch = { spy.calls.append("delete \($0.id) branch \($1)") }
      let screen = OffscreenWindow(
        SidebarHarness(spy: spy, actions: actions), width: 300, height: 800)
      defer { screen.close() }
      let menu = try #require(try screen.menu(ofRow: SidebarFixture.betaRow))
      try screen.choose("Delete\u{2026}", in: menu)
      #expect(screen.window.attachedSheet != nil)
      #expect(spy.calls.isEmpty)
      // The branch's box, Cancel, Delete.
      try screen.clickControl(at: 1)
      #expect(spy.calls.isEmpty)
      #expect(screen.window.attachedSheet == nil)

      try screen.choose("Delete\u{2026}", in: menu)
      try screen.clickControl(at: 0)
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.calls == ["delete beta branch true"])
    }

    @Test("Delete on a session without a worktree asks in a dialog instead")
    func dialogFlow() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      var actions = spy.actions
      actions.sessions.deleteWithBranch = { spy.calls.append("delete \($0.id) branch \($1)") }
      let screen = OffscreenWindow(
        SidebarHarness(spy: spy, actions: actions), width: 300, height: 800)
      defer { screen.close() }
      let menu = try #require(try screen.menu(ofRow: SidebarFixture.betaRow))
      try screen.choose("Delete\u{2026}", in: menu)
      #expect(screen.window.attachedSheet == nil)
      #expect(spy.calls == ["delete beta"])
    }

    @Test("the worktree preference decides, unless cleanup can't run")
    func archiveDecision() {
      let ids: Set<String> = ["a"]
      func decide(_ ids: Set<String>, _ supported: Bool, _ preference: String?)
        -> ArchiveWorktreeDecision
      {
        .resolve(worktreeSessionIDs: ids, cleanupSupported: supported, preference: preference)
      }
      #expect(decide(ids, false, "true") == .archive(deletingWorktrees: []))
      #expect(decide([], true, "true") == .archive(deletingWorktrees: []))
      #expect(decide(ids, true, "true") == .archive(deletingWorktrees: ids))
      #expect(decide(ids, true, "false") == .archive(deletingWorktrees: []))
      #expect(decide(ids, true, nil) == .ask(worktreeSessionIDs: ids))
      #expect(decide(ids, true, "junk") == .ask(worktreeSessionIDs: ids))
    }

    private struct PromptHost: View {
      let spy: SidebarSpy
      @State private var request: ArchiveWorktreeRequest?

      init(spy: SidebarSpy, request: ArchiveWorktreeRequest) {
        self.spy = spy
        _request = State(initialValue: request)
      }

      var body: some View {
        Color.clear.archiveWorktreePrompt($request) { request, delete, remember in
          spy.calls.append("choose \(request.sessionIDs) \(delete) \(remember)")
        }
      }
    }

    @Test("the worktree prompt reports the choice, and Cancel reports nothing")
    func archivePrompt() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let one = ArchiveWorktreeRequest(sessionIDs: ["a"], worktreeSessionIDs: ["a"])
      SystemSideEffects.answer(alert: .alertFirstButtonReturn)
      let screen = OffscreenWindow(PromptHost(spy: spy, request: one), width: 300, height: 200)
      defer { screen.close() }
      #expect(SystemSideEffects.record.alertMessages.contains("Also delete the worktree?"))
      #expect(spy.calls == [#"choose ["a"] true false"#])

      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      let many = ArchiveWorktreeRequest(sessionIDs: ["a", "b"], worktreeSessionIDs: ["a", "b"])
      let second = OffscreenWindow(PromptHost(spy: spy, request: many), width: 300, height: 200)
      defer { second.close() }
      #expect(SystemSideEffects.record.alertMessages.contains("Also delete the worktrees?"))
      #expect(spy.calls.last == #"choose ["a", "b"] false false"#)

      spy.calls = []
      SystemSideEffects.answer(alert: .alertThirdButtonReturn)
      let third = OffscreenWindow(PromptHost(spy: spy, request: one), width: 300, height: 200)
      defer { third.close() }
      #expect(spy.calls.isEmpty)
      #expect(one.id == ["a"])
    }

    @Test("a reasoned menu button is disabled with its reason as the tooltip")
    func reasoned() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let enabled = OffscreenWindow(
        ReasonedMenuButton("Fork", systemImage: "arrow.branch", unavailableReason: nil) {
          spy.calls.append("fork")
        }, width: 200, height: 50)
      defer { enabled.close() }
      try enabled.clickControl(at: 0)
      #expect(spy.calls == ["fork"])
      let disabled = OffscreenWindow(
        ReasonedMenuButton("Fork", systemImage: "arrow.branch", unavailableReason: "Busy") {
          spy.calls.append("fork again")
        }, width: 200, height: 50)
      defer { disabled.close() }
      try disabled.click(CGPoint(x: 100, y: 25))
      #expect(spy.calls == ["fork"])
    }

    @Test("a payload only reads back when it's ours")
    func dragPayload() {
      #expect(SidebarDragItem(payload: SidebarDragItem.session("s").payload) == .session("s"))
      #expect(SidebarDragItem(payload: SidebarDragItem.project("p").payload) == .project("p"))
      #expect(SidebarDragItem(payload: "https://example.test") == nil)
    }
  }
#endif
