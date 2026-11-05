import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@MainActor
struct NewSessionWorktreeSeedTests {
  private static let repository = CreationLoad<[HostWorktree]>.loaded([
    HostWorktree(path: "/r", branch: "main", isMain: true),
    HostWorktree(path: "/r-wt", branch: "wt", isMain: false),
  ])

  private func seed(
    _ choice: NewSessionWorktreeChoice = .none, folder: String = "/r",
    worktrees: CreationLoad<[HostWorktree]> = repository, alwaysUse: Bool = true,
    previous: WorktreeSeed? = nil
  ) -> (choice: NewSessionWorktreeChoice, seed: WorktreeSeed?) {
    NewSessionAdapter.seededWorktree(
      choice, folder: folder, isRepository: NewSessionAdapter.isRepository(worktrees),
      defaults: WorktreeDefaults(
        alwaysUse: alwaysUse, base: " main ", makeBranch: { "worktree-abcd1234" }),
      previous: previous)
  }

  @Test func aGitFolderStartsOnAFreshBranchFromTheDefaultBase() {
    let result = seed()
    #expect(result.choice == .new(branch: "worktree-abcd1234", base: "main"))
    #expect(result.seed == WorktreeSeed(folder: "/r", branch: "worktree-abcd1234"))
  }

  @Test func nothingIsChosenOutsideARepositoryOrBeforeItsWorktreesAreRead() {
    #expect(seed(worktrees: .loaded([])).choice == NewSessionWorktreeChoice.none)
    #expect(seed(worktrees: .loading).choice == NewSessionWorktreeChoice.none)
    #expect(seed(folder: "").choice == NewSessionWorktreeChoice.none)
    #expect(seed(alwaysUse: false).choice == NewSessionWorktreeChoice.none)
  }

  @Test func theUsersOwnChoiceStandsAndAFolderIsSeededOnce() {
    let existing = NewSessionWorktreeChoice.existing(
      NewSessionWorktreeOption(path: "/r-wt", branch: "wt"))
    #expect(seed(existing).choice == existing)
    // Choosing "No worktree" after the seed is not undone for the same folder.
    let earlier = WorktreeSeed(folder: "/r", branch: "worktree-old")
    let kept = seed(previous: earlier)
    #expect(kept.choice == NewSessionWorktreeChoice.none)
    #expect(kept.seed == earlier)
    // A new folder is seeded again.
    #expect(seed(folder: "/s", previous: earlier).seed?.folder == "/s")
  }

  @Test func turningTheSettingOffTakesBackOnlyItsOwnBranch() {
    let earlier = WorktreeSeed(folder: "/r", branch: "worktree-old")
    let own = seed(.new(branch: "worktree-old", base: "main"), alwaysUse: false, previous: earlier)
    #expect(own.choice == NewSessionWorktreeChoice.none)
    #expect(own.seed == nil)
    let named = NewSessionWorktreeChoice.new(branch: "feature", base: "")
    #expect(seed(named, alwaysUse: false, previous: earlier).choice == named)
  }

  @Test func randomBranchesFollowTheWebsShape() {
    let branch = NewSessionAdapter.randomWorktreeBranch()
    #expect(branch.hasPrefix("worktree-"))
    #expect(branch.count == "worktree-".count + 8)
    #expect(isValidBranchName(name: branch))
  }
}
