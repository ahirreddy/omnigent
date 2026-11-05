public import Foundation

/// What the Pull Requests tab shows for the PR the user opened.
nonisolated public enum PullRequestDetailContent: Hashable, Sendable {
  /// The first read is in flight.
  case loading
  /// The read failed, with the host's reason.
  case failed(String)
  /// There is nothing to show, and why.
  case unavailable(title: String, message: String, systemImage: String)
  /// The PR.
  case ready(PullRequestDetailViewState)
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
  /// Labels can be changed.
  public var canEditLabels: Bool
  /// Reviews can be requested and withdrawn.
  public var canEditReviewers: Bool
  /// Comments can be posted.
  public var canComment: Bool
  /// How many files changed, once the patch is read.
  public var fileCount: Int?

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
  /// Clears the last failure.
  public var dismissError: (@MainActor () -> Void)?

  /// No actions.
  public init() {}
}
