import OmnigentCoreFFI

/// The composer clears the moment Send is pressed. What left the field is kept as an
/// ``UnsentSend`` until the server accepts it: a refusal returns it to the field while the field
/// is still empty, and otherwise offers it back, so text typed since is never overwritten. It is
/// in the saved draft meanwhile, so quitting loses nothing, and it is never sent again on its own.
extension ComposerStore {
  /// Sends the draft with its uploaded files and `@` paths. While another send is in flight it
  /// joins the queue and leaves once that one is accepted. A message the server refuses because
  /// the session's host is offline waits in the queue for the host.
  func deliverMessage() async {
    guard !isSending else {
      if let queued = enqueueDraft() { followUps.insert(queued) }
      return
    }
    let message = draftMessage
    let draft = fieldDraft
    let extras: MessageQueue.Extras
    do {
      extras = try takeExtras()
    } catch {
      // A file still uploading keeps everything in the draft, with the reason shown.
      lastError = coreError(error)
      return
    }
    let unsent = UnsentSend(draft: draft, extras: extras)
    let pendingRow = transcript?.showSending(
      message, attachments: extras.files.map(PendingMessages.attachment))
    let failure = await deliver(unsent) { core, session in
      let sent = try await core.sendQueuedMessage(
        sessionId: session, text: message, hold: extras.holdID,
        harness: configuration?.harness, paths: extras.mentions)
      transcript?.messageAccepted(pendingRow, sent)
    }
    guard let failure else {
      await sendFollowUps()
      return
    }
    transcript?.messageNotSent(pendingRow)
    guard failure.isHostOffline else {
      giveBack(unsent, failure: failure)
      return
    }
    queue.hold(message, extras: extras)
    lastError = nil
    commandNotice = failure.message
    draftStored?(savedDraft)
    scheduleHostRecheck()
  }

  /// Sends the draft as a command the server runs (a skill, `/compact`). A command does not
  /// queue: while another send is in flight it stays in the field with the reason.
  /// - Parameter post: Posts the command's text for a session.
  func deliverCommand(
    _ post: (ClientCore, String, String) async throws -> MessageSent
  ) async {
    guard !refusesDuringSend() else { return }
    let text = draftMessage
    let unsent = UnsentSend(draft: fieldDraft)
    let failure = await deliver(unsent) { core, session in
      _ = try await post(core, session, text)
    }
    if let failure {
      giveBack(unsent, failure: failure)
    } else {
      await sendFollowUps()
    }
  }

  /// Says why a command that posts cannot run while a send is in flight.
  /// - Returns: Whether a send is in flight.
  func refusesDuringSend() -> Bool {
    guard isSending else { return false }
    lastError = .InvalidState(message: "Wait for the current send to finish.")
    return true
  }

  /// Puts the offered messages back in the field, oldest first, after what was typed since.
  /// Files that cannot return leave their message offered, with the reason shown.
  public func restoreUnsent() {
    while let offer = unsentOffers.first {
      guard restoreHeldFiles(offer.extras.holdID) else { return }
      unsentOffers.removeFirst()
      restore(fieldDraft.appending(offer.draft))
    }
  }

  /// Drops the offered messages and their files.
  public func discardUnsent() {
    guard !unsentOffers.isEmpty else { return }
    let offers = unsentOffers
    unsentOffers = []
    for offer in offers { discardHeldFiles(offer.extras.holdID) }
    draftStored?(savedDraft)
  }

  /// Posts a message that leaves the field now and is kept as `unsent` until the server answers.
  /// - Parameters:
  ///   - unsent: What the field held.
  ///   - post: Posts it for a session.
  /// - Returns: Why it was not accepted (also ``lastError``), or `nil` once it was.
  private func deliver(
    _ unsent: UnsentSend, _ post: (ClientCore, String) async throws -> Void
  ) async -> CoreError? {
    lastError = nil
    commandNotice = nil
    inFlight = unsent
    clearDraft()
    isSending = true
    defer {
      isSending = false
      refreshBlocked()
    }
    do {
      try await post(core, sessionID)
    } catch {
      inFlight = nil
      let failure = coreError(error)
      lastError = failure
      return failure
    }
    inFlight = nil
    draftStored?(savedDraft)
    return nil
  }

  /// Returns a message that was not accepted: to the field while it is still empty, else as an
  /// offer the user restores or drops.
  private func giveBack(_ unsent: UnsentSend, failure: CoreError) {
    if fieldDraft.isEmpty, attachments.items.isEmpty, restoreHeldFiles(unsent.extras.holdID) {
      restore(unsent.draft)
      return
    }
    var offer = unsent
    offer.failure = Self.failureNote(failure)
    unsentOffers.append(offer)
    draftStored?(savedDraft)
  }
}
