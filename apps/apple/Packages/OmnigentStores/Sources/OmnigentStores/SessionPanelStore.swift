import Foundation
public import Observation
public import OmnigentCoreFFI
public import OmnigentWorkspaceUI

/// The right panel's server data for one session: which panel features the server offers
/// (content search, stored pull requests), the session's linked pull requests, and the open
/// pull request's live detail, which the session's host reads from its provider.
@Observable
public final class SessionPanelStore {
  /// The session.
  public let sessionID: String
  /// The server's panel features, once read; `nil` until then, or after a failed read
  /// (``featuresError``).
  public private(set) var features: PanelFeatures?
  /// Why the features could not be read.
  public private(set) var featuresError: CoreError?
  /// The linked pull requests.
  public private(set) var pullRequests: CreationLoad<SessionPullRequests> = .idle
  /// The pull request the panel shows in detail; `nil` shows the list.
  public internal(set) var openPullRequest: String?
  /// The open pull request's live detail.
  public internal(set) var detail: CreationLoad<PullRequestInfo> = .idle
  /// The open pull request's patch, parsed, pinned to the revision the detail shows.
  public internal(set) var files: CreationLoad<PullRequestFiles> = .idle
  /// The open pull request's changed-file list, pinned to the same revision.
  public internal(set) var changes: CreationLoad<PullRequestChanges> = .idle
  /// Each pull request's Changes tab view, by URL, kept while the app runs.
  public internal(set) var changesViews: [String: PullRequestChangesTabState] = [:]
  /// Unchanged context read to expand the open pull request's files, by path.
  public internal(set) var fileContext: [String: DiffContextState] = [:]
  /// The open pull request's commits, at the head its list shows.
  public internal(set) var commits: CreationLoad<PullRequestCommits> = .idle
  /// Pull requests whose server or host lacks the commit routes.
  public internal(set) var commitsUnsupported: Set<String> = []
  /// The patch of the commit the Changes tab shows, or of the changes since a commit.
  public internal(set) var commitPatch: CreationLoad<PullRequestFiles> = .idle
  /// The session's local review comments on pull request diffs.
  public internal(set) var localComments: CreationLoad<[LocalReviewComment]> = .idle
  /// A local review comment the composer asked the Changes tab to show.
  public internal(set) var localCommentTarget: LocalReviewComment?
  /// The open pull request's detail should switch to its Changes tab.
  public internal(set) var opensChangesTab = false
  /// The Changes diff's layout, unified or side by side, kept across launches.
  public var diffLayout: DiffLayoutMode {
    didSet { preferences.set(diffLayout.rawValue, forKey: Self.diffLayoutKey) }
  }
  /// The labels the open pull request's repository offers, read when the label menu opens.
  public internal(set) var repositoryLabels: CreationLoad<RepositoryLabels> = .idle
  /// Who a review can be requested from, read when the reviewer menu opens.
  public internal(set) var reviewCandidates: CreationLoad<ReviewCandidates> = .idle
  /// The merge methods the repository allows, read when the merge sheet opens.
  public internal(set) var mergeOptions: CreationLoad<MergeOptions> = .idle
  /// The change in flight, if any; one runs at a time.
  public internal(set) var pendingEdit: PullRequestEdit?
  /// Why the last change failed.
  public internal(set) var editError: CoreError?
  /// Each linked pull request's condition as its host last read it, for the composer's chip.
  public internal(set) var liveConditions: [String: PullRequestCondition] = [:]
  /// Each linked pull request's checks as its host last read them, where it can read them.
  public internal(set) var liveChecks: [String: PullRequestChecks] = [:]
  /// The last read of the linked pull requests found the session's host offline.
  public internal(set) var linkedHostOffline = false
  /// The open pull request's inline review threads, read while the Changes tab shows.
  public internal(set) var reviewThreads: CreationLoad<ReviewThreadsPage> = .idle
  /// The lines a new review thread is being written on, and its text.
  public internal(set) var newReviewThread: ReviewThreadDraft?
  /// Replies being written, by thread.
  public internal(set) var reviewReplies: [String: String] = [:]

  let core: ClientCore
  private var generation = 0
  var detailGeneration = 0
  /// The head the shown files were read at; a poll re-reads them only when it moves.
  @ObservationIgnored var filesHead: String?
  /// How many views of each kind watch the PRs (``watch(_:resumed:)``).
  @ObservationIgnored var watchers: [PullRequestWatcher: Int] = [:]
  @ObservationIgnored var pollTask: Task<Void, Never>?
  /// The poll found nothing to watch and stopped; the next read from outside restarts it.
  @ObservationIgnored var pollRests = false
  let pollTimer: any PullRequestPollTimer
  /// The commit or "since" start ``commitPatch`` was read for.
  @ObservationIgnored var commitPatchKey: String?
  /// The listed head ``commits`` was read at.
  @ObservationIgnored var commitsReadHead: String?
  /// Bumps scroll requests so a repeated one is new.
  @ObservationIgnored var scrollTokens = 0
  /// Where viewed marks are kept on this device.
  public let viewedMarks: PullRequestViewedMarks
  /// The server and the signed-in user viewed marks are kept under; `nil` keeps none.
  @ObservationIgnored public var viewedScope: (@MainActor () -> PullRequestViewedScope?)?
  /// Attaches a new local review comment to the session's composer.
  @ObservationIgnored public var attachReviewComment: (@MainActor (LocalReviewComment) -> Void)?
  /// Takes a deleted local review comment off the session's composer.
  @ObservationIgnored public var detachReviewComment: (@MainActor (String) -> Void)?
  /// Where the new-thread card's destination choice is remembered.
  let preferences: UserDefaults

  init(
    sessionID: String, core: ClientCore,
    pollTimer: any PullRequestPollTimer = SystemPullRequestPollTimer(),
    viewedMarks: PullRequestViewedMarks = .shared, preferences: UserDefaults = .standard
  ) {
    self.sessionID = sessionID
    self.core = core
    self.pollTimer = pollTimer
    self.viewedMarks = viewedMarks
    self.preferences = preferences
    diffLayout =
      preferences.string(forKey: Self.diffLayoutKey).flatMap(DiffLayoutMode.init) ?? .unified
  }

  /// Whether the server stores pull requests; `false` until the features are read.
  public var offersPullRequests: Bool { features?.pullRequests == true }

  /// Whether the session workspace can be searched by content.
  public var offersContentSearch: Bool { features?.contentSearch == true }

  /// Reads the panel features once; a failure is kept and retried on the next call.
  public func loadFeatures() async {
    guard features == nil else { return }
    do {
      features = try await core.panelFeatures()
      featuresError = nil
    } catch {
      featuresError = coreError(error)
    }
  }

  /// Reads the linked pull requests when the server stores them. The previous list stays on
  /// screen while it reloads; a read started later wins over one still in flight.
  public func reloadPullRequests() async {
    await readPullRequests()
    resumePollingIfRested()
  }

  /// One read of the linked pull requests and their live conditions.
  /// - Returns: Whether a live read found the session's host offline.
  @discardableResult
  func readPullRequests() async -> Bool {
    await loadFeatures()
    guard offersPullRequests else { return false }
    generation += 1
    let current = generation
    if pullRequests.value == nil { pullRequests = .loading }
    let result: CreationLoad<SessionPullRequests>
    do {
      result = .loaded(try await core.sessionPullRequests(sessionId: sessionID))
    } catch {
      result = .failed(coreError(error))
    }
    if current == generation, pullRequests != result { pullRequests = result }
    return await refreshLiveConditions()
  }

  /// Re-reads the pull requests when they were read before, and the open one, for example
  /// after a turn that may have opened or pushed to one.
  public func refreshPullRequestsIfShown() async {
    guard pullRequests != .idle else { return }
    await reloadPullRequests()
    await reloadDetail()
  }
}

extension ConnectionStore {
  /// The right panel's server data for `sessionID`.
  /// - Parameter sessionID: The session.
  /// - Returns: The store, or `nil` when the core did not start.
  public func makePanelStore(_ sessionID: String) -> SessionPanelStore? {
    guard let core else { return nil }
    let store = SessionPanelStore(sessionID: sessionID, core: core)
    store.viewedScope = { [weak self] in
      self?.connectedServer.map {
        PullRequestViewedScope(server: $0.baseUrl, user: $0.userId)
      }
    }
    return store
  }
}
