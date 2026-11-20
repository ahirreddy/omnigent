import Testing

@testable import OmnigentUIComponents

/// The editor's Random worktree row, as the web's: a switch for a Git folder, and for a saved
/// worktree whose folder can't be confirmed, why, with a way to turn it off.
@Suite("Automation random worktree row")
struct AutomationWorktreeRowTests {
  @Test("It shows for a repository folder on a host, or while a saved worktree is on")
  func shows() {
    var draft = AutomationDraftState(agentID: "a1")
    draft.hostID = "h1"
    draft.workspace = "/work"
    #expect(AutomationWorktreeRow.shows(draft, check: .repository))
    #expect(!AutomationWorktreeRow.shows(draft, check: .notRepository))
    draft.baseBranch = AutomationWorktreeRow.baseRef
    #expect(AutomationWorktreeRow.shows(draft, check: .hostOffline))
    draft.runsInSandbox = true
    #expect(!AutomationWorktreeRow.shows(draft, check: .repository))
    draft.runsInSandbox = false
    draft.workspace = ""
    #expect(!AutomationWorktreeRow.shows(draft, check: .repository))
  }

  @Test("Its help follows session continuity and its status the check")
  func wording() {
    #expect(AutomationWorktreeRow.help(continuesSession: true).hasSuffix("Later runs reuse it."))
    #expect(AutomationWorktreeRow.help(continuesSession: false).hasSuffix("for each run."))
    #expect(
      AutomationWorktreeCheck.hostOffline.status == "Connect your host to verify this directory.")
  }
}
