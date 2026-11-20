import SwiftUI

/// The editor's Random worktree switch under the Workspace row (the web's): each run starts in
/// a randomly named worktree from the repository's current HEAD. It shows only for a Git folder;
/// a saved one whose folder can't be confirmed says why, with a way to turn it off.
struct AutomationWorktreeRow: View {
  @Binding var draft: AutomationDraftState
  let check: AutomationWorktreeCheck

  /// The ref a random worktree branches from (the web's `RANDOM_WORKTREE_BASE_REF`).
  static let baseRef = "HEAD"

  /// Whether the row shows: a folder on a host that is a repository, or a saved worktree.
  static func shows(_ draft: AutomationDraftState, check: AutomationWorktreeCheck) -> Bool {
    guard !draft.runsInSandbox, !draft.workspace.isEmpty else { return false }
    return check == .repository || draft.baseBranch != nil
  }

  /// What the switch does, which depends on whether runs share a session.
  static func help(continuesSession: Bool) -> String {
    continuesSession
      ? "Creates a randomly named worktree from the repository\u{2019}s current HEAD when starting a session. Later runs reuse it."
      : "Creates a fresh randomly named worktree from the repository\u{2019}s current HEAD for each run."
  }

  var body: some View {
    if check == .repository {
      Toggle(isOn: isOn) {
        Text("Random worktree")
        Text(Self.help(continuesSession: draft.continuesSession))
      }
      .accessibilityIdentifier("automation-random-worktree")
    } else {
      VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
        Text("Random worktree is enabled. \(check.status)")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("Turn Off Random Worktree") { draft.baseBranch = nil }
          .buttonStyle(.borderless)
          .accessibilityIdentifier("automation-random-worktree-off")
      }
    }
  }

  private var isOn: Binding<Bool> {
    Binding(
      get: { draft.baseBranch != nil },
      set: { draft.baseBranch = $0 ? Self.baseRef : nil })
  }
}
