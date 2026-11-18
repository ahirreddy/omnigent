public import OmnigentCoreFFI
import OmnigentWorkspaceUI

/// Local review comments: comments for the session's agent on lines of a pull request's diff,
/// as the web's `LocalReviewComment` keeps them. They are session comments carrying the diff's
/// coordinates (`/v1/info.comment_anchor_metadata`); a new one goes to the composer, which sends
/// it with the next message.
extension SessionPanelStore {
  /// Whether the server keeps a comment's place on a pull request's diff.
  public var offersLocalComments: Bool { features?.commentAnchors == true }

  /// The open pull request's local comments.
  public var openLocalComments: [LocalReviewComment] {
    guard let url = openPullRequest else { return [] }
    return (localComments.value ?? []).filter { $0.anchor.prUrl == url }
  }

  /// Whether a local comment was written at another revision than the patch on screen.
  /// - Parameter comment: The comment.
  /// - Returns: Whether it is from an earlier revision.
  public func isEarlier(_ comment: LocalReviewComment) -> Bool {
    let revision = reviewRevision
    return comment.anchor.headSha != revision.head || comment.anchor.baseSha != revision.base
  }

  /// Reads the session's local review comments; a failed re-read keeps what shows.
  public func loadLocalComments() async {
    await loadFeatures()
    guard offersLocalComments else { return }
    if localComments.value == nil { localComments = .loading }
    do {
      let comments = try await core.sessionReviewComments(sessionId: sessionID)
      if localComments != .loaded(comments) { localComments = .loaded(comments) }
    } catch {
      if localComments.value == nil { localComments = .failed(coreError(error)) }
    }
    revealLocalCommentIfReady()
  }

  /// Posts the new thread's draft as a local comment and attaches it to the composer.
  /// - Returns: Whether it was posted.
  func startLocalComment() async -> Bool {
    guard let url = openPullRequest, let draft = newReviewThread else { return false }
    guard offersLocalComments else {
      editError = .InvalidState(
        message: "Agent comments require a newer server. Your draft is saved.")
      return false
    }
    let revision = reviewRevision
    guard let head = revision.head, let base = revision.base else { return false }
    let anchor = ReviewCommentAnchor(
      prUrl: url, side: draft.side, line: draft.end,
      startLine: draft.start == draft.end ? nil : draft.start, headSha: head, baseSha: base)
    let comment = await edit(.reviewComment) { core, session in
      try await core.addReviewComment(
        sessionId: session, path: draft.path, body: draft.body, anchor: anchor)
    }
    await loadLocalComments()
    guard let comment else { return false }
    if newReviewThread == draft { newReviewThread = nil }
    attachReviewComment?(comment)
    return true
  }

  /// Changes a local comment's text.
  /// - Parameters:
  ///   - id: The comment.
  ///   - body: The new text.
  /// - Returns: Whether it changed.
  @discardableResult
  public func editLocalComment(_ id: String, body: String) async -> Bool {
    let edited = await edit(.reviewComment) { core, session in
      try await core.updateSessionComment(
        sessionId: session, commentId: id, body: body, open: nil)
    }
    await loadLocalComments()
    return edited != nil
  }

  /// Deletes a local comment and takes it off the composer.
  /// - Parameter id: The comment.
  /// - Returns: Whether it was deleted.
  @discardableResult
  public func deleteLocalComment(_ id: String) async -> Bool {
    let deleted: Void? = await edit(.reviewComment) { core, session in
      try await core.deleteSessionComment(sessionId: session, commentId: id)
    }
    guard deleted != nil else { return false }
    detachReviewComment?(id)
    await loadLocalComments()
    return true
  }

  /// Shows `comment` in its pull request's Changes tab: the PR opens, filters that would hide
  /// the file clear, and the diff scrolls to the comment once it is read.
  /// - Parameter comment: The comment.
  public func revealLocalComment(_ comment: LocalReviewComment) async {
    localCommentTarget = comment
    opensChangesTab = true
    if openPullRequest != comment.anchor.prUrl {
      await showPullRequest(comment.anchor.prUrl)
    }
    updateChangesView { view in
      view.mode = .changes
      view.sinceSha = nil
      view.pathFilter = ""
      view.hideViewed = false
    }
    await loadLocalComments()
  }

  /// The detail switched to its Changes tab as ``opensChangesTab`` asked.
  public func changesTabOpened() {
    if opensChangesTab { opensChangesTab = false }
  }

  /// Once the target comment's PR and comments are read, shows it, or says it is gone.
  func revealLocalCommentIfReady() {
    guard let target = localCommentTarget, openPullRequest == target.anchor.prUrl,
      localComments.value != nil, files.value != nil
    else { return }
    localCommentTarget = nil
    guard let comment = openLocalComments.first(where: { $0.id == target.id }) else {
      editError = .InvalidState(message: "This review comment is no longer available.")
      return
    }
    let path = comment.path
    if isEarlier(comment) { setEarlierCommentsShown(path, true) }
    reveal(path)
    let side: DiffLineAnchor.Side = comment.anchor.side == .left ? .old : .new
    scroll(to: .line(path: path, side: side, line: comment.anchor.line))
  }
}
