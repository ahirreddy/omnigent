import Testing

@testable import OmnigentUIComponents

struct SessionHeaderAndArchiveTests {
  @Test("Archiving working agents is worded as the web words it, for one and for several")
  func archiveRunningWording() {
    let one = ArchiveRunningRequest(sessionIDs: ["a"], runningCount: 1)
    #expect(one.title == "Archive running session?")
    #expect(
      one.message
        == "This session's agent is still working. Archiving stops it. You can unarchive the "
        + "session later.")
    let some = ArchiveRunningRequest(sessionIDs: ["a", "b", "c"], runningCount: 1)
    #expect(some.title == "Archive a running session?")
    #expect(some.message.hasPrefix("1 of the 3 sessions you're archiving has an agent"))
    let many = ArchiveRunningRequest(sessionIDs: ["a", "b", "c"], runningCount: 2)
    #expect(many.title == "Archive 2 running sessions?")
    #expect(
      many.message
        == "2 of the 3 sessions you're archiving have agents still working. Archiving stops "
        + "them. You can unarchive sessions later.")
  }
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

  @Test("The session menu's context names the project the session is filed in")
  func menuContextProject() {
    let projects = [SessionProject(id: "p", name: "Alpha", sessionIds: [], icon: "🚀")]
    #expect(SessionMenuContext(projects: projects, projectID: "p").project?.name == "Alpha")
    #expect(SessionMenuContext(projects: projects).project == nil)
    #expect(SessionMenuContext(projects: projects, projectID: "gone").project == nil)
  }
}
