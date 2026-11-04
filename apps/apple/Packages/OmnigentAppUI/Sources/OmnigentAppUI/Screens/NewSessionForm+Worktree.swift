import Foundation
import OmnigentStores
import OmnigentUIComponents

extension NewSessionForm {
  /// Settings › Git's worktree defaults, as saved now.
  var worktreeDefaults: WorktreeDefaults {
    WorktreeDefaults(
      alwaysUse: preferences.bool(forKey: GitPreferences.alwaysUseWorktreeKey),
      base: preferences.string(forKey: GitPreferences.defaultBaseBranchKey) ?? "")
  }

  /// Starts a git folder on a fresh worktree branch when Settings › Git asks for one, and takes
  /// that branch back when the setting is turned off.
  func seedWorktree(_ creation: CreationStore) {
    guard !isSandbox else { return }
    let seeded = NewSessionAdapter.seededWorktree(
      worktree, folder: folder, isRepository: NewSessionAdapter.isRepository(creation.worktrees),
      defaults: worktreeDefaults, previous: worktreeSeed)
    worktreeSeed = seeded.seed
    guard seeded.choice != worktree else { return }
    worktree = seeded.choice
    applyWorktree()
  }
}
