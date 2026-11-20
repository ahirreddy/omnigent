public import Foundation

/// What the Pull Requests tab shows for the PR the user opened.
nonisolated public enum PullRequestDetailContent: Hashable, Sendable {
  /// The first read is in flight.
  case loading
  /// The read failed, with the host's reason.
  case failed(String)
  /// There is nothing to show, and why.
  case unavailable(title: String, message: String, systemImage: String)
  /// The host is offline: the PR as the server stored it.
  case stored(PullRequestStoredViewState)
  /// The PR.
  case ready(PullRequestDetailViewState)

  /// The PR page and the provider's name, for Open on GitHub; `nil` before the PR is known.
  public var link: (url: String, providerName: String)? {
    switch self {
    case .ready(let state): (state.url, state.providerName)
    case .stored(let state): (state.url, state.providerName)
    case .loading, .failed, .unavailable: nil
    }
  }
}

/// The CI checks in one bucket.
nonisolated public struct PullRequestCheckGroup: Hashable, Sendable, Identifiable {
  /// The bucket.
  public enum Bucket: String, Hashable, Sendable, CaseIterable {
    /// Passed.
    case passed
    /// Running.
    case pending
    /// Failed.
    case failed
    /// Cancelled.
    case cancelled
    /// Skipped.
    case skipped
  }

  /// One check.
  public struct Run: Hashable, Sendable {
    /// The job name.
    public var name: String
    /// Its page.
    public var url: URL?

    /// Creates a check.
    /// - Parameters:
    ///   - name: Name.
    ///   - url: Page.
    public init(name: String, url: URL?) {
      self.name = name
      self.url = url
    }
  }

  /// The bucket.
  public var bucket: Bucket
  /// How many.
  public var count: Int
  /// The checks, by name.
  public var runs: [Run]
  /// Stable id.
  public var id: Bucket { bucket }

  /// Creates a group.
  /// - Parameters:
  ///   - bucket: The bucket.
  ///   - count: How many.
  ///   - runs: The checks.
  public init(bucket: Bucket, count: Int, runs: [Run]) {
    self.bucket = bucket
    self.count = count
    self.runs = runs
  }
}

/// A reviewer or a label, and anything the panel can choose from (merge methods included).
nonisolated public struct PullRequestChip: Hashable, Sendable, Identifiable {
  /// Stable id: a login with its kind, a label name, or a merge method.
  public var id: String
  /// What it shows.
  public var title: String
  /// A second line, for example a review's state or a display name.
  public var detail: String?
  /// An SF Symbol.
  public var systemImage: String?
  /// A label's color, `0xRRGGBB`.
  public var color: UInt32?

  /// Creates a chip.
  /// - Parameters:
  ///   - id: Id.
  ///   - title: Title.
  ///   - detail: Second line.
  ///   - systemImage: Symbol.
  ///   - color: Label color.
  public init(
    id: String, title: String, detail: String? = nil, systemImage: String? = nil,
    color: UInt32? = nil
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.systemImage = systemImage
    self.color = color
  }
}

/// Choices read on demand (repository labels, review candidates, merge methods).
nonisolated public enum PullRequestChoices: Hashable, Sendable {
  /// Not read yet.
  case idle
  /// Reading.
  case loading
  /// The read failed.
  case failed(String)
  /// The choices.
  case loaded([PullRequestChip])
}

/// What the merge area shows.
nonisolated public enum PullRequestMergeState: Hashable, Sendable {
  /// Auto-merge is on.
  case autoMerge
  /// GitHub is still computing whether it can merge.
  case checking(String)
  /// It cannot merge yet, and why.
  case blocked(String)
  /// It can merge, with an optional caveat.
  case ready(String?)
}

/// A conversation comment.
nonisolated public struct PullRequestCommentRow: Hashable, Sendable, Identifiable {
  /// Stable id.
  public var id: String
  /// The author.
  public var author: String
  /// When, for display.
  public var date: Date?
  /// Markdown.
  public var body: String
  /// Its page.
  public var url: URL?

  /// Creates a comment row.
  /// - Parameters:
  ///   - id: Id.
  ///   - author: Author.
  ///   - date: When.
  ///   - body: Markdown.
  ///   - url: Page.
  public init(id: String, author: String, date: Date?, body: String, url: URL?) {
    self.id = id
    self.author = author
    self.date = date
    self.body = body
    self.url = url
  }
}

/// The open PR's header, Summary and Comments.
nonisolated public struct PullRequestDetailViewState: Hashable, Sendable {
  /// The PR page.
  public var url: String
  /// The title.
  public var title: String
  /// "#7", or "!7" on Azure DevOps.
  public var numberLabel: String
  /// The status chip.
  public var status: PullRequestSummary.Status
  /// "owner/repo · branch → base".
  public var context: String
  /// The provider's name, for "Open on GitHub".
  public var providerName: String
  /// Markdown description.
  public var body: String?
  /// Checks per bucket, empty buckets left out.
  public var checks: [PullRequestCheckGroup] = []
  /// A note above the checks (some unreadable, or none readable).
  public var checksNote: String?
  /// Reviewers.
  public var reviewers: [PullRequestChip] = []
  /// The host reports reviewers, so the section shows.
  public var showsReviewers = false
  /// Labels.
  public var labels: [PullRequestChip] = []
  /// The host reports labels, so the section shows.
  public var showsLabels = false
  /// The merge area; `nil` hides it.
  public var merge: PullRequestMergeState?
  /// Conversation comments, oldest first.
  public var comments: [PullRequestCommentRow]
  /// Some comments could not be read.
  public var commentsPartial: Bool
  /// Commits and force pushes, oldest first.
  public var timeline: [PullRequestTimelineRow] = []
  /// Some commit and push history could not be read.
  public var timelinePartial = false
  /// The title and description can be edited.
  public var canEditDetails = false
  /// Images and videos can be uploaded into the description.
  public var canAttach = false
  /// Labels can be changed.
  public var canEditLabels: Bool
  /// Reviews can be requested and withdrawn.
  public var canEditReviewers: Bool
  /// Comments can be posted.
  public var canComment: Bool
  /// How many files changed, once the patch is read.
  public var fileCount: Int?
  /// The PR's author, whom the provider refuses as a reviewer.
  public var author: String?
  /// The reviewers with a pending request, by chip id.
  public var requestedReviewers: Set<String> = []
  /// The provider account comments post as; `nil` when the host doesn't say.
  public var account: String?
  /// The accounts a merge can run as; empty when the merge can't choose one.
  public var mergeAccounts: [PullRequestAccountChoice] = []

  /// Creates a detail with nothing editable.
  /// - Parameters:
  ///   - url: Page.
  ///   - title: Title.
  ///   - numberLabel: "#7".
  ///   - status: Status.
  ///   - context: Repository and branches.
  ///   - providerName: Provider.
  public init(
    url: String, title: String, numberLabel: String, status: PullRequestSummary.Status,
    context: String, providerName: String
  ) {
    self.url = url
    self.title = title
    self.numberLabel = numberLabel
    self.status = status
    self.context = context
    self.providerName = providerName
    comments = []
    commentsPartial = false
    canEditLabels = false
    canEditReviewers = false
    canComment = false
  }
}

extension PullRequestDetailViewState {
  /// Comments and commit activity in one feed, by time; without activity, the comments' own
  /// order stands. Entries with no time go last.
  public var feed: [PullRequestFeedEntry] {
    let entries =
      comments.map(PullRequestFeedEntry.comment) + timeline.map(PullRequestFeedEntry.event)
    guard !timeline.isEmpty else { return entries }
    return entries.enumerated().sorted { left, right in
      let leftDate = left.element.date ?? .distantFuture
      let rightDate = right.element.date ?? .distantFuture
      return leftDate == rightDate ? left.offset < right.offset : leftDate < rightDate
    }
    .map(\.element)
  }
}

/// How an attachment upload ended.
nonisolated public enum PullRequestAttachmentOutcome: Hashable, Sendable {
  /// Uploaded: the Markdown that embeds it.
  case attached(markdown: String)
  /// Not uploaded, and why.
  case failed(String)
}

/// The Pull Requests tab's actions. `nil` hides the control.
public struct PullRequestPanelActions {
  /// Shows a linked PR in detail.
  public var select: (@MainActor (String) -> Void)?
  /// Back to the list.
  public var showList: (@MainActor () -> Void)?
  /// Links a PR by address; the callback says whether it was linked.
  public var link: (@MainActor (String, @escaping @MainActor (Bool) -> Void) -> Void)?
  /// Unlinks a PR.
  public var unlink: (@MainActor (String) -> Void)?
  /// Re-reads the list and the open PR.
  public var refresh: (@MainActor () -> Void)?
  /// Keeps the PRs fresh while the tab shows, until its task is cancelled; the argument says
  /// the tab shows again after being hidden.
  public var watch: (@MainActor (_ resumed: Bool) async -> Void)?
  /// Reads the repository's labels.
  public var loadLabels: (@MainActor () -> Void)?
  /// Adds (`true`) or removes a label by name.
  public var setLabel: (@MainActor (String, Bool) -> Void)?
  /// Reads who a review can be requested from.
  public var loadReviewers: (@MainActor () -> Void)?
  /// Requests (`true`) or withdraws a review, by chip id.
  public var setReviewer: (@MainActor (String, Bool) -> Void)?
  /// Reads the merge methods.
  public var loadMergeMethods: (@MainActor () -> Void)?
  /// Merges with the method of that chip id.
  public var merge: (@MainActor (String) -> Void)?
  /// Turns off auto-merge.
  public var disableAutoMerge: (@MainActor () -> Void)?
  /// Posts a comment; the callback says whether it was posted.
  public var comment: (@MainActor (String, @escaping @MainActor (Bool) -> Void) -> Void)?
  /// Why a comment can't be posted as written (too long), or `nil`.
  public var commentProblem: (@MainActor (String) -> String?)?
  /// Replaces the title and/or the description (`nil` keeps one); the callback says whether it
  /// was saved.
  public var editDetails:
    (
      @MainActor (_ title: String?, _ body: String?, _ done: @escaping @MainActor (Bool) -> Void)
        -> Void
    )?
  /// Uploads an image or video for the description; the callback gets the Markdown that embeds
  /// it, or why it failed.
  public var attach:
    (
      @MainActor (_ file: URL, _ done: @escaping @MainActor (PullRequestAttachmentOutcome) -> Void)
        -> Void
    )?
  /// Clears the last failure.
  public var dismissError: (@MainActor () -> Void)?
  /// The detail switched to its Changes tab as ``PullRequestPanelExtras/opensChanges`` asked.
  public var changesOpened: (@MainActor () -> Void)?
  /// Saves the provider account the host reads and writes the PR as.
  public var setAccount: (@MainActor (String) -> Void)?
  /// Merges with the method of that chip id as that account.
  public var mergeAs: (@MainActor (_ method: String, _ account: String) -> Void)?

  /// No actions.
  public init() {}
}
