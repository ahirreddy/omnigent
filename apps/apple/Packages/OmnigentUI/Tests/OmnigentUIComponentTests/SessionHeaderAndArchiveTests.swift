import Testing

@testable import OmnigentUIComponents

struct SessionHeaderAndArchiveTests {
  @Test("Archive asks about worktrees only when it applies and nothing is remembered")
  func archiveWorktreeDecision() {
    let worktrees: Set<String> = ["a", "b"]
    let decide = { (ids: Set<String>, supported: Bool, preference: String?) in
      ArchiveWorktreeDecision.resolve(
        worktreeSessionIDs: ids, cleanupSupported: supported, preference: preference)
    }
    #expect(decide(worktrees, true, nil) == .ask(worktreeSessionIDs: worktrees))
    // Settings › Git's "Ask each time" stores an empty string.
    #expect(decide(worktrees, true, "") == .ask(worktreeSessionIDs: worktrees))
    #expect(decide(worktrees, true, "true") == .archive(deletingWorktrees: worktrees))
    #expect(decide(worktrees, true, "false") == .archive(deletingWorktrees: []))
    // An older server, or sessions without worktrees, archive without asking or deleting.
    #expect(decide(worktrees, false, "true") == .archive(deletingWorktrees: []))
    #expect(decide([], true, nil) == .archive(deletingWorktrees: []))
  }

  @Test("The header's project tag is for the viewer's own top-level sessions")
  func projectTagApplies() {
    let projects = [SessionProject(id: "p", name: "Alpha", sessionIds: [], icon: "🚀")]
    let own = SessionMenuContext(projects: projects, projectID: "p")
    #expect(own.project?.name == "Alpha")
    #expect(HeaderProjectTag.applies(own, isSubagent: false, canMove: true))
    #expect(!HeaderProjectTag.applies(own, isSubagent: true, canMove: true))
    #expect(!HeaderProjectTag.applies(own, isSubagent: false, canMove: false))
    let shared = SessionMenuContext(projects: projects, isShared: true)
    #expect(!HeaderProjectTag.applies(shared, isSubagent: false, canMove: true))
    #expect(!HeaderProjectTag.applies(SessionMenuContext(), isSubagent: false, canMove: true))
  }
}
