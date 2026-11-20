import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Whether the editor's pinned folder is a Git repository, for Random worktree (the web's
/// `useHostWorktrees` read of the host's worktrees for that folder).
extension AutomationsMapping {
  /// The folder to check: a host's absolute path, and whether that host is online.
  struct WorktreeQuery: Hashable {
    let hostID: String
    let path: String
    let isOnline: Bool
  }

  /// The folder `draft` pins on a host; `nil` in a sandbox or without one.
  @MainActor
  static func worktreeQuery(_ draft: AutomationDraftState, pages: PagesStore) -> WorktreeQuery? {
    let path = draft.workspace.trimmingCharacters(in: .whitespaces)
    guard !draft.runsInSandbox, !draft.hostID.isEmpty, path.hasPrefix("/") else { return nil }
    let host = pages.automationCatalog.value?.hosts.first { $0.hostId == draft.hostID }
    return WorktreeQuery(hostID: draft.hostID, path: path, isOnline: host?.status == "online")
  }

  /// Lists a host's folders for the Workspace row's Browse; `nil` without a creation store.
  @MainActor
  static func folderBrowser(_ creation: CreationStore?)
    -> (@MainActor (String, String?) async -> Result<FolderListing, FolderBrowseError>)?
  {
    guard let creation else { return nil }
    return { hostID, path in
      await creation.directory(hostID: hostID, path: path)
        .map(NewSessionAdapter.listing)
        .mapError { FolderBrowseError(message: $0.message) }
    }
  }

  /// What the host says about `query`'s folder.
  @MainActor
  static func worktreeCheck(_ query: WorktreeQuery?, creation: CreationStore?) async
    -> AutomationWorktreeCheck
  {
    guard let query else { return .notRepository }
    guard query.isOnline else { return .hostOffline }
    guard let creation else { return .unavailable }
    switch await creation.worktrees(hostID: query.hostID, path: query.path) {
    case .success(let worktrees): return worktrees.isEmpty ? .notRepository : .repository
    case .failure: return .unavailable
    }
  }
}
