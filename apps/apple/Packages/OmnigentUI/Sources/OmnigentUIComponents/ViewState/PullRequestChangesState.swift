public import Foundation
public import OmnigentWorkspaceUI
public import SwiftUI

/// One commit as the Commits view and the "Changes since" picker list it.
nonisolated public struct PullRequestCommitRow: Hashable, Sendable, Identifiable {
  /// The full id.
  public var sha: String
  /// The first line of the message.
  public var title: String
  /// The git author.
  public var author: String?
  /// When it was authored.
  public var date: Date?
  /// "Head of #41" when it heads another pull request.
  public var headOf: String?

  /// The id.
  public var id: String { sha }
  /// The first seven characters of the id.
  public var shortSha: String { String(sha.prefix(7)) }

  /// Creates a row.
  /// - Parameters:
  ///   - sha: Id.
  ///   - title: Title.
  ///   - author: Author.
  ///   - date: Authored.
  ///   - headOf: Other PRs it heads.
  public init(sha: String, title: String, author: String?, date: Date?, headOf: String?) {
    self.sha = sha
    self.title = title
    self.author = author
    self.date = date
    self.headOf = headOf
  }

  /// Commits whose id, title or author contains `query`, ignoring case (the web's
  /// `filterCommits`).
  /// - Parameters:
  ///   - commits: The list.
  ///   - query: The search.
  /// - Returns: The matches, in order.
  public static func filter(_ commits: [Self], query: String) -> [Self] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return commits }
    return commits.filter { commit in
      [commit.sha, commit.title, commit.author ?? ""].contains { $0.lowercased().contains(needle) }
    }
  }
}

/// The commit list's state.
nonisolated public struct PullRequestCommitsState: Hashable, Sendable {
  /// Oldest first.
  public var commits: [PullRequestCommitRow] = []
  /// The provider has more than it listed.
  public var hasMore = false
  /// The most commits listed.
  public var limit: UInt64 = 250
  /// Being read with none shown.
  public var isLoading = false
  /// The history cannot be read here.
  public var isUnavailable = false
  /// Why the read failed.
  public var error: String?
  /// The search.
  public var query = ""

  /// An empty list.
  public init() {}
}

/// The bar over one commit's patch: back to the list, and to the older or newer commit.
nonisolated public struct PullRequestCommitBarState: Hashable, Sendable {
  /// The commit.
  public var sha: String
  /// Its title, when the list has it.
  public var title: String?
  /// The older commit.
  public var previous: String?
  /// The newer commit.
  public var next: String?

  /// Creates the bar.
  public init(sha: String, title: String?, previous: String?, next: String?) {
    self.sha = sha
    self.title = title
    self.previous = previous
    self.next = next
  }
}

/// The find bar.
nonisolated public struct PullRequestFindState: Hashable, Sendable {
  /// Shows the field.
  public var isOpen = false
  /// The query.
  public var query = ""
  /// Case-sensitive.
  public var matchCase = false
  /// A regular expression.
  public var regex = false
  /// "3 of 12", "No results", "Invalid".
  public var status = ""
  /// Matches to step through.
  public var total = 0
  /// "+4 in hidden files" when the filters hide matches.
  public var hidden: String?

  /// A closed bar.
  public init() {}
}

/// The viewed count, its bar and Hide viewed.
nonisolated public struct PullRequestViewedProgress: Hashable, Sendable {
  /// Viewed files.
  public var viewed: Int
  /// Listed files.
  public var total: Int
  /// The list is truncated, so the total is a lower bound.
  public var partial: Bool
  /// Viewed files are hidden.
  public var hideViewed: Bool

  /// Creates the progress.
  public init(viewed: Int, total: Int, partial: Bool, hideViewed: Bool) {
    self.viewed = viewed
    self.total = total
    self.partial = partial
    self.hideViewed = hideViewed
  }

  /// "2 / 5 files viewed (partial)".
  public var label: String {
    "\(viewed) / \(total) files viewed\(partial ? " (partial)" : "")"
  }
}

/// The "Changes since" picker: the PR base, or one of its commits.
nonisolated public struct PullRequestChangesSinceState: Hashable, Sendable {
  /// Newest first, without the head.
  public var commits: [PullRequestCommitRow] = []
  /// The picked commit, or `nil` for the PR base.
  public var selected: String?
  /// "Since PR base", "Since abc1234".
  public var label = "Since PR base"
  /// The list is being read.
  public var isLoading = false
  /// Why it failed; opening the picker again retries.
  public var error: String?
  /// Only the first commits are listed.
  public var limitNote: String?

  /// The base.
  public init() {}
}

/// What the Changes tab's body shows.
public enum PullRequestChangesBody {
  /// The commit list.
  case commits(PullRequestCommitsState)
  /// A message in place of the files, with a button when something clears it.
  case message(String, isLoading: Bool, action: (title: String, run: @MainActor () -> Void)?)
  /// The files.
  case diff(StackedDiffContent)
}

/// A file of the sidebar's tree.
nonisolated public struct PullRequestTreeFile: Hashable, Sendable {
  /// The file.
  public var path: String
  /// How it changed.
  public var kind: ChangedFileKind
  /// Added lines.
  public var added: UInt64?
  /// Removed lines.
  public var removed: UInt64?

  /// Creates a file.
  public init(path: String, kind: ChangedFileKind, added: UInt64?, removed: UInt64?) {
    self.path = path
    self.kind = kind
    self.added = added
    self.removed = removed
  }
}

/// Comments on files the diff can't show: earlier revisions and files without a diff.
public struct PullRequestUnavailableComments: Identifiable {
  /// The file.
  public var path: String
  /// File actions (show earlier comments).
  public var actions: AnyView?
  /// The comments.
  public var comments: AnyView

  /// The path.
  public var id: String { path }

  /// Creates a group.
  public init(path: String, actions: AnyView?, comments: AnyView) {
    self.path = path
    self.actions = actions
    self.comments = comments
  }
}

/// The Changes tab, as the web's `PullRequestChangesTab` lays it out.
public struct PullRequestChangesState {
  /// Why review conversations are incomplete or failed.
  public var reviewNotice: String?
  /// More review conversations can be read.
  public var hasMoreThreads = false
  /// Why the changed-file list is incomplete.
  public var listingNotice: String?
  /// What find covers when the patch lacks some files.
  public var coverageNote: String?
  /// "New commits since you last viewed".
  public var showsResetNotice = false
  /// The Changes | Commits switch shows: the provider lists commits.
  public var offersCommits = false
  /// The switch is on Commits.
  public var showsCommitList = false
  /// The "Changes since" picker, in Changes with commits.
  public var changesSince: PullRequestChangesSinceState?
  /// The file list, layout and collapse controls show.
  public var showsFileControls = false
  /// Unresolved conversations can be stepped through.
  public var canNavigateThreads = false
  /// Review conversations are being read.
  public var isLoadingThreads = false
  /// Unified or side by side.
  public var layout = DiffLayoutMode.unified
  /// Every visible file is collapsed.
  public var allCollapsed = false
  /// The find bar; `nil` in the commit list.
  public var find: PullRequestFindState?
  /// The viewed progress, while marks are available.
  public var progress: PullRequestViewedProgress?
  /// The bar over an open commit.
  public var commitBar: PullRequestCommitBarState?
  /// The sidebar's files (after the filters).
  public var treeFiles: [PullRequestTreeFile] = []
  /// What the sidebar says instead of files.
  public var treeMessage: String?
  /// The sidebar is loading.
  public var treeLoading = false
  /// Viewed files, checked in the tree.
  public var viewedPaths: Set<String> = []
  /// The file at the top of the diff.
  public var activePath: String?
  /// The path filter.
  public var pathFilter = ""
  /// The filter field shows (there are files to filter).
  public var offersFilter = false
  /// The body.
  public var body = PullRequestChangesBody.message("", isLoading: true, action: nil)
  /// Comments on files the diff can't show.
  public var unavailable: [PullRequestUnavailableComments] = []
  /// Local comments could not be read.
  public var localCommentsFailed = false

  /// An empty tab.
  public init() {}
}

/// What the Changes tab's controls do. `nil` leaves a control out.
public struct PullRequestChangesActions {
  /// Reads more review conversations.
  public var loadMoreThreads: (@MainActor () -> Void)?
  /// Dismisses the viewed-marks notice.
  public var dismissResetNotice: (@MainActor () -> Void)?
  /// Shows commits (`true`) or changes.
  public var showCommits: (@MainActor (Bool) -> Void)?
  /// Picks the "Changes since" commit, or `nil` for the base.
  public var setSince: (@MainActor (String?) -> Void)?
  /// The "Changes since" picker opened; reads the commits.
  public var openSince: (@MainActor () -> Void)?
  /// Steps to the next (`true`) or previous unresolved conversation.
  public var navigateThread: (@MainActor (Bool) -> Void)?
  /// Switches unified and side by side.
  public var setLayout: (@MainActor (DiffLayoutMode) -> Void)?
  /// Collapses or expands every visible file.
  public var toggleAll: (@MainActor () -> Void)?
  /// Opens or closes the find bar.
  public var setFindOpen: (@MainActor (Bool) -> Void)?
  /// Changes the find query.
  public var setFindQuery: (@MainActor (String) -> Void)?
  /// Toggles match case.
  public var toggleMatchCase: (@MainActor () -> Void)?
  /// Toggles regular expressions.
  public var toggleRegex: (@MainActor () -> Void)?
  /// Steps to the next (`true`) or previous match.
  public var stepFind: (@MainActor (Bool) -> Void)?
  /// Clears the filters hiding matches.
  public var showHidden: (@MainActor () -> Void)?
  /// Hides or shows viewed files.
  public var setHideViewed: (@MainActor (Bool) -> Void)?
  /// Back from a commit to the list.
  public var backToCommits: (@MainActor () -> Void)?
  /// Opens a commit.
  public var openCommit: (@MainActor (String) -> Void)?
  /// Changes the commit search.
  public var setCommitQuery: (@MainActor (String) -> Void)?
  /// Jumps to a file from the tree.
  public var jumpToFile: (@MainActor (String) -> Void)?
  /// Changes the path filter.
  public var setPathFilter: (@MainActor (String) -> Void)?
  /// Reads the local comments again.
  public var retryLocalComments: (@MainActor () -> Void)?
  /// The diff's own actions.
  public var diff = StackedDiffActions()

  /// No actions.
  public init() {}
}
