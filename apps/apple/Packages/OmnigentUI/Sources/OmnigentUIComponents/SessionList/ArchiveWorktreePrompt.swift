public import SwiftUI

/// What archiving does with the sessions' git worktrees, as the web's `useArchiveWorktreePrompt`:
/// remove them, keep them, or ask, from Settings › Git's "When archiving a worktree session".
nonisolated public enum ArchiveWorktreeDecision: Hashable, Sendable {
  /// Archive now, removing the worktrees of these sessions (none to archive only).
  case archive(deletingWorktrees: Set<String>)
  /// Ask first; these sessions have worktrees.
  case ask(worktreeSessionIDs: Set<String>)

  /// The decision for archiving sessions.
  /// - Parameters:
  ///   - worktreeSessionIDs: The sessions being archived that have a git worktree.
  ///   - cleanupSupported: The server can remove worktrees on archive.
  ///   - preference: The saved ``GitPreferences/deleteWorktreesOnArchiveKey`` value.
  /// - Returns: The decision.
  public static func resolve(
    worktreeSessionIDs: Set<String>, cleanupSupported: Bool, preference: String?
  ) -> Self {
    guard cleanupSupported, !worktreeSessionIDs.isEmpty else {
      return .archive(deletingWorktrees: [])
    }
    switch preference {
    case "true": return .archive(deletingWorktrees: worktreeSessionIDs)
    case "false": return .archive(deletingWorktrees: [])
    default: return .ask(worktreeSessionIDs: worktreeSessionIDs)
    }
  }
}

/// An archive waiting on the worktree question.
nonisolated public struct ArchiveWorktreeRequest: Hashable, Sendable, Identifiable {
  /// The sessions being archived.
  public var sessionIDs: [String]
  /// Those of them with a git worktree.
  public var worktreeSessionIDs: Set<String>

  /// The sessions, as the dialog's identity.
  public var id: [String] { sessionIDs }

  /// Creates a request.
  /// - Parameters:
  ///   - sessionIDs: The sessions being archived.
  ///   - worktreeSessionIDs: Those with a worktree.
  public init(sessionIDs: [String], worktreeSessionIDs: Set<String>) {
    self.sessionIDs = sessionIDs
    self.worktreeSessionIDs = worktreeSessionIDs
  }
}

extension View {
  /// Asks whether archiving also deletes the sessions' worktrees, with "Remember my choice".
  /// Dismissing the dialog cancels the archive.
  /// - Parameters:
  ///   - request: The pending archive; `nil` hides the dialog.
  ///   - choose: Called with whether to delete the worktrees and whether to remember that.
  /// - Returns: The view with the dialog.
  public func archiveWorktreePrompt(
    _ request: Binding<ArchiveWorktreeRequest?>,
    choose: @escaping @MainActor (ArchiveWorktreeRequest, _ delete: Bool, _ remember: Bool) -> Void
  ) -> some View {
    modifier(ArchiveWorktreePrompt(request: request, choose: choose))
  }
}

private struct ArchiveWorktreePrompt: ViewModifier {
  @Binding var request: ArchiveWorktreeRequest?
  let choose: @MainActor (ArchiveWorktreeRequest, Bool, Bool) -> Void
  @State private var remember = false

  private var isPlural: Bool { (request?.worktreeSessionIDs.count ?? 0) > 1 }

  func body(content: Content) -> some View {
    content.confirmationDialog(
      isPlural ? "Also delete the worktrees?" : "Also delete the worktree?",
      isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
      titleVisibility: .visible, presenting: request
    ) { pending in
      Button(isPlural ? "Delete Worktrees" : "Delete Worktree", role: .destructive) {
        finish(pending, delete: true)
      }
      .accessibilityIdentifier("archive-worktree-delete")
      Button("Archive Only") { finish(pending, delete: false) }
        .accessibilityIdentifier("archive-worktree-keep")
      Button("Cancel", role: .cancel) { remember = false }
    } message: { pending in
      let count = pending.worktreeSessionIDs.count
      Text(
        (count > 1
          ? "\(count) of the sessions you're archiving have a git worktree."
          : "This session has a git worktree.")
          + " Deleting removes the worktree folder, including uncommitted changes. The branch is"
          + " kept. You can change this in Settings › Git.")
    }
    .dialogSuppressionToggle("Remember my choice", isSuppressed: $remember)
  }

  private func finish(_ pending: ArchiveWorktreeRequest, delete: Bool) {
    let remembered = remember
    remember = false
    request = nil
    choose(pending, delete, remembered)
  }
}
