public import Observation
public import OmnigentCoreFFI

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
  /// The open pull request's changed files, parsed from its patch.
  public internal(set) var files: CreationLoad<PullRequestFiles> = .idle
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

  let core: ClientCore
  private var generation = 0
  var detailGeneration = 0

  init(sessionID: String, core: ClientCore) {
    self.sessionID = sessionID
    self.core = core
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
    await loadFeatures()
    guard offersPullRequests else { return }
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
    await refreshLiveConditions()
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
    return SessionPanelStore(sessionID: sessionID, core: core)
  }
}
