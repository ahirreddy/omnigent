public import OmnigentCoreFFI

/// A new review thread being written: the lines it goes on and its text.
nonisolated public struct ReviewThreadDraft: Equatable, Sendable {
  /// The file.
  public var path: String
  /// The side of the diff.
  public var side: ReviewSide
  /// The first line.
  public var start: UInt64
  /// The last line, where the thread shows.
  public var end: UInt64
  /// The hunk the lines are in.
  public var hunk: Int
  /// The comment.
  public var body: String

  /// Creates a draft.
  /// - Parameters:
  ///   - path: File.
  ///   - side: Side.
  ///   - start: First line.
  ///   - end: Last line.
  ///   - hunk: The hunk.
  ///   - body: Comment.
  public init(
    path: String, side: ReviewSide, start: UInt64, end: UInt64, hunk: Int = 0, body: String = ""
  ) {
    self.path = path
    self.side = side
    self.start = min(start, end)
    self.end = max(start, end)
    self.hunk = hunk
    self.body = body
  }
}

/// The open PR's inline review threads, as the web's `usePullRequestReviewThreads`: read while
/// the Changes tab shows and every 10 seconds there, paged, replied to and started from lines.
extension SessionPanelStore {
  /// How often the Changes tab re-reads the threads.
  static let reviewThreadsPoll = Duration.seconds(10)

  private var reviewsReadable: Bool { detail.value?.capabilities.reviewThreads == true }

  /// Reads the first page of threads, keeping older comments and later pages already read at
  /// the same revision. A failed re-read keeps what shows.
  public func loadReviewThreads() async {
    guard let url = openPullRequest, reviewsReadable else { return }
    if reviewThreads.value == nil { reviewThreads = .loading }
    do {
      let page = try await core.pullRequestReviewThreads(
        sessionId: sessionID, prUrl: url, afterCursor: nil, headSha: "", baseSha: "")
      guard openPullRequest == url else { return }
      let merged = Self.reconcile(page, previous: reviewThreads.value)
      if reviewThreads != .loaded(merged) { reviewThreads = .loaded(merged) }
    } catch {
      guard openPullRequest == url, reviewThreads.value == nil else { return }
      reviewThreads = .failed(coreError(error))
    }
  }

  /// Reads threads while the Changes tab shows, until the calling task is cancelled.
  public func watchReviewThreads() async {
    while !Task.isCancelled {
      await loadReviewThreads()
      await pollTimer.wait(Self.reviewThreadsPoll)
    }
  }

  /// Reads the next page of threads at the first page's revision.
  public func loadMoreReviewThreads() async {
    guard let url = openPullRequest, let page = reviewThreads.value,
      let cursor = page.nextCursor
    else { return }
    do {
      let next = try await core.pullRequestReviewThreads(
        sessionId: sessionID, prUrl: url, afterCursor: cursor, headSha: page.headSha,
        baseSha: page.baseSha)
      guard openPullRequest == url, var current = reviewThreads.value,
        current.headSha == next.headSha, current.baseSha == next.baseSha
      else { return }
      current.threads = Self.merging(current.threads, next.threads)
      current.hasMore = next.hasMore
      current.nextCursor = next.nextCursor
      reviewThreads = .loaded(current)
    } catch {
      editError = coreError(error)
    }
  }

  /// Reads a thread's older comments.
  /// - Parameter threadID: The thread.
  public func loadOlderReviewComments(_ threadID: String) async {
    guard let url = openPullRequest,
      let thread = reviewThreads.value?.threads.first(where: { $0.id == threadID }),
      let cursor = thread.comments.nextCursor
    else { return }
    do {
      let older = try await core.reviewThreadComments(
        sessionId: sessionID, prUrl: url, threadId: threadID, cursor: cursor)
      guard openPullRequest == url else { return }
      updateThread(threadID) { thread in
        thread.comments.comments = Self.merging(thread.comments.comments, older.comments)
        thread.comments.hasMore = older.hasMore
        thread.comments.nextCursor = older.nextCursor
        thread.comments.warning = older.warning
      }
    } catch {
      editError = coreError(error)
    }
  }

  /// Keeps a reply's text while it is written.
  /// - Parameters:
  ///   - text: The reply.
  ///   - threadID: Its thread.
  public func setReviewReply(_ text: String, for threadID: String) {
    if reviewReplies[threadID] != text { reviewReplies[threadID] = text.isEmpty ? nil : text }
  }

  /// Replies to a thread with its draft.
  /// - Parameter threadID: The thread.
  /// - Returns: Whether the reply was posted.
  @discardableResult
  public func replyToReviewThread(_ threadID: String) async -> Bool {
    guard let url = openPullRequest, let body = reviewReplies[threadID] else { return false }
    let comment = await edit(.reviewComment) { core, session in
      try await core.replyToReviewThread(
        sessionId: session, prUrl: url, threadId: threadID, body: body)
    }
    guard let comment, openPullRequest == url else { return false }
    if reviewReplies[threadID] == body { reviewReplies[threadID] = nil }
    updateThread(threadID) { thread in
      thread.comments.comments = Self.merging(thread.comments.comments, [comment])
    }
    return true
  }

  /// Starts writing a thread on lines of one side; a draft's text stays when the lines change.
  /// - Parameter lines: The lines.
  public func selectReviewLines(_ lines: ReviewThreadDraft) {
    var draft = lines
    draft.body = newReviewThread?.body ?? lines.body
    if newReviewThread != draft { newReviewThread = draft }
  }

  /// Keeps the new thread's text while it is written.
  /// - Parameter text: The comment.
  public func setNewReviewThreadBody(_ text: String) {
    if newReviewThread?.body != text { newReviewThread?.body = text }
  }

  /// Drops the new thread.
  public func cancelNewReviewThread() {
    if newReviewThread != nil { newReviewThread = nil }
  }

  /// Posts the new thread at the revision on screen.
  /// - Returns: Whether it was posted.
  @discardableResult
  public func startReviewThread() async -> Bool {
    guard let url = openPullRequest, let draft = newReviewThread,
      let pullRequest = detail.value?.pullRequest, let head = pullRequest.headSha,
      let base = pullRequest.baseSha
    else { return false }
    let anchor = ReviewAnchor(
      path: draft.path, side: draft.side, line: draft.end,
      startLine: draft.start == draft.end ? nil : draft.start, headSha: head, baseSha: base)
    let thread = await edit(.reviewComment) { core, session in
      try await core.createReviewThread(
        sessionId: session, prUrl: url, body: draft.body, anchor: anchor)
    }
    guard let thread, openPullRequest == url else { return false }
    if newReviewThread == draft { newReviewThread = nil }
    if var page = reviewThreads.value, page.headSha == head, page.baseSha == base {
      page.threads = Self.merging(page.threads, [thread])
      reviewThreads = .loaded(page)
    }
    return true
  }

  private func updateThread(_ threadID: String, _ change: (inout ReviewThread) -> Void) {
    guard var page = reviewThreads.value,
      let index = page.threads.firstIndex(where: { $0.id == threadID })
    else { return }
    change(&page.threads[index])
    reviewThreads = .loaded(page)
  }

  /// A first page, with what the previous read at the same revision paged in kept: older
  /// comments, replies the provider hasn't listed yet, and later pages of threads.
  static func reconcile(_ page: ReviewThreadsPage, previous: ReviewThreadsPage?)
    -> ReviewThreadsPage
  {
    guard let previous, previous.headSha == page.headSha, previous.baseSha == page.baseSha
    else { return page }
    if page.warning != nil, page.threads.isEmpty {
      var kept = previous
      kept.warning = page.warning
      return kept
    }
    var merged = page
    merged.threads = page.threads.map { thread in
      guard let old = previous.threads.first(where: { $0.id == thread.id }) else { return thread }
      var thread = thread
      thread.comments.comments = merging(old.comments.comments, thread.comments.comments)
      return thread
    }
    let first = Set(page.threads.map(\.id))
    let later = previous.threads.dropFirst(page.threads.count).filter { !first.contains($0.id) }
    if !later.isEmpty {
      merged.threads += later
      merged.hasMore = previous.hasMore
      merged.nextCursor = previous.nextCursor
    }
    return merged
  }

  /// `current` with `incoming` added, the incoming copy of an id winning.
  static func merging(_ current: [ReviewThread], _ incoming: [ReviewThread]) -> [ReviewThread] {
    var merged = current
    for thread in incoming {
      if let index = merged.firstIndex(where: { $0.id == thread.id }) {
        merged[index] = thread
      } else {
        merged.append(thread)
      }
    }
    return merged
  }

  /// Comments by id, oldest first (the web's `mergeReviewComments`).
  static func merging(_ current: [ReviewComment], _ incoming: [ReviewComment]) -> [ReviewComment] {
    var byID: [String: ReviewComment] = [:]
    var order: [String] = []
    for comment in current + incoming {
      if byID[comment.id] == nil { order.append(comment.id) }
      byID[comment.id] = comment
    }
    return order.compactMap { byID[$0] }.enumerated()
      .sorted { ($0.element.createdAt ?? "", $0.offset) < ($1.element.createdAt ?? "", $1.offset) }
      .map(\.element)
  }
}
