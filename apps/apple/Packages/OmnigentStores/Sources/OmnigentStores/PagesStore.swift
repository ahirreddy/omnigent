import Foundation
public import Observation
public import OmnigentCoreFFI

/// Where an Inbox reply stands.
public enum ReplyState: Equatable, Sendable {
  /// The reply is in flight.
  case sending
  /// The server took it; `since` is the session's last activity when it was sent, so the
  /// agent's answer can be told apart.
  case sent(since: Int64)
  /// It was not sent; the draft stays.
  case failed(CoreError)
}

/// The top-level pages beside the sessions: which ones the server offers, Automations, Usage,
/// and the Inbox's file comments and replies. Each failure stays with what it failed to load.
@Observable
public final class PagesStore {
  /// The pages the server offers; `nil` until read.
  public private(set) var offered: ServerPages?
  /// The caller's automations.
  public private(set) var automations: CreationLoad<[Automation]> = .idle
  /// Automations with a write in flight.
  public private(set) var busyAutomationIDs: Set<String> = []
  /// The last failed automation write, until dismissed.
  public private(set) var automationError: CoreError?
  /// The agents an automation can run.
  public private(set) var automationAgents: CreationLoad<[CreationAgent]> = .idle
  /// The caller's spend.
  public private(set) var usage: CreationLoad<UsageReport> = .idle
  /// File comments by session, for sessions that report some.
  public private(set) var comments: [String: [FileComment]] = [:]
  /// Sessions whose comments could not be read.
  public private(set) var commentErrors: [String: CoreError] = [:]
  /// Comments the user opened or dismissed from the Inbox.
  public private(set) var seenCommentIDs: Set<String> = []
  /// Inbox replies by session.
  public private(set) var replies: [String: ReplyState] = [:]
  /// Unread sessions' latest agent output, by session.
  public private(set) var latestOutputs: [String: LatestOutput] = [:]
  /// Sessions whose latest output could not be read.
  public private(set) var outputErrors: [String: CoreError] = [:]

  private let core: ClientCore
  private let defaults: UserDefaults
  private var seenKey: String?
  /// The comment count each session's list was read at.
  private var commentCounts: [String: UInt64] = [:]
  /// The activity each session's latest output was read at.
  private var outputStamps: [String: Int64] = [:]

  init(core: ClientCore, defaults: UserDefaults = .standard) {
    self.core = core
    self.defaults = defaults
  }

  /// Reads which pages the server offers. A failure leaves them unoffered.
  /// - Returns: The failure, if any.
  @discardableResult
  public func loadOffered() async -> CoreError? {
    do {
      offered = try await core.serverPages()
      return nil
    } catch {
      return coreError(error)
    }
  }

  // MARK: Automations

  /// Reads the automations; a reload keeps the list on screen until it lands.
  public func loadAutomations() async {
    if automations.value == nil { automations = .loading }
    do {
      automations = .loaded(try await core.automations())
    } catch {
      automations = .failed(coreError(error))
    }
  }

  /// Creates an automation, or saves `id`'s edits.
  /// - Parameters:
  ///   - draft: What to save.
  ///   - id: The automation being edited; `nil` creates one.
  /// - Returns: Whether it was saved; a failure is in ``automationError``.
  @discardableResult
  public func saveAutomation(_ draft: AutomationDraft, editing id: String?) async -> Bool {
    await writeAutomation(id) { core in
      if let id {
        _ = try await core.updateAutomation(id: id, draft: draft)
      } else {
        _ = try await core.createAutomation(draft: draft)
      }
    }
  }

  /// Pauses or resumes `id`.
  @discardableResult
  public func setAutomationPaused(_ id: String, _ paused: Bool) async -> Bool {
    await writeAutomation(id) { core in
      _ = try await core.setAutomationPaused(id: id, paused: paused)
    }
  }

  /// Starts a run of `id` now.
  @discardableResult
  public func runAutomation(_ id: String) async -> Bool {
    await writeAutomation(id) { core in try await core.runAutomation(id: id) }
  }

  /// Deletes `id`; its sessions stay.
  @discardableResult
  public func deleteAutomation(_ id: String) async -> Bool {
    await writeAutomation(id) { core in try await core.deleteAutomation(id: id) }
  }

  /// Reads the agents an automation can run, unless they are loaded.
  public func loadAutomationAgents() async {
    if automationAgents.value != nil { return }
    automationAgents = .loading
    do {
      automationAgents = .loaded(try await core.creationCatalog().agents)
    } catch {
      automationAgents = .failed(coreError(error))
    }
  }

  /// Clears ``automationError`` after the user has seen it.
  public func dismissAutomationError() {
    automationError = nil
  }

  private func writeAutomation(_ id: String?, _ operation: (ClientCore) async throws -> Void)
    async -> Bool
  {
    if let id {
      guard busyAutomationIDs.insert(id).inserted else { return false }
    }
    defer { if let id { busyAutomationIDs.remove(id) } }
    do {
      try await operation(core)
      automationError = nil
    } catch {
      automationError = coreError(error)
      return false
    }
    await loadAutomations()
    return true
  }

  // MARK: Usage

  /// Reads the spend report.
  public func loadUsage() async {
    if usage.value == nil { usage = .loading }
    do {
      usage = .loaded(try await core.usageReport())
    } catch {
      usage = .failed(coreError(error))
    }
  }

  // MARK: Inbox

  /// Reads the comments of every listed session whose comment count changed since its last
  /// read, and forgets sessions that no longer have any.
  /// - Parameter sessions: The session list.
  public func refreshComments(_ sessions: [SessionSummary]) async {
    let counts = Dictionary(
      sessions.filter { !$0.isArchived && $0.commentsCount > 0 }.map { ($0.id, $0.commentsCount) },
      uniquingKeysWith: { first, _ in first })
    for id in comments.keys where counts[id] == nil { comments[id] = nil }
    for id in commentErrors.keys where counts[id] == nil { commentErrors[id] = nil }
    commentCounts = commentCounts.filter { counts[$0.key] != nil }
    for (id, count) in counts.sorted(by: { $0.key < $1.key })
    where commentCounts[id] != count || commentErrors[id] != nil {
      commentCounts[id] = count
      do {
        comments[id] = try await core.sessionComments(sessionId: id)
        commentErrors[id] = nil
      } catch {
        commentErrors[id] = coreError(error)
      }
    }
  }

  /// Reads the latest output of each of `sessions` whose activity changed since its last read,
  /// and forgets the others.
  /// - Parameter sessions: The unread sessions.
  public func refreshLatestOutputs(_ sessions: [SessionSummary]) async {
    let wanted = Dictionary(
      sessions.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { first, _ in first })
    for id in latestOutputs.keys where wanted[id] == nil { latestOutputs[id] = nil }
    for id in outputErrors.keys where wanted[id] == nil { outputErrors[id] = nil }
    outputStamps = outputStamps.filter { wanted[$0.key] != nil }
    for (id, updatedAt) in wanted.sorted(by: { $0.key < $1.key })
    where outputStamps[id] != updatedAt || outputErrors[id] != nil {
      outputStamps[id] = updatedAt
      do {
        latestOutputs[id] = try await core.latestOutput(sessionId: id)
        outputErrors[id] = nil
      } catch {
        outputErrors[id] = coreError(error)
      }
    }
  }

  /// The comments the Inbox lists: open, by someone else, unseen; newest first.
  /// - Parameter viewerID: The signed-in user.
  /// - Returns: The comments.
  public func unseenComments(viewerID: String?) -> [FileComment] {
    commentInbox(
      comments: comments.values.flatMap { $0 }, seenIds: Array(seenCommentIDs), viewerId: viewerID)
  }

  /// Loads the comments already seen on this device for `key` (one server and user).
  /// - Parameter key: The defaults key.
  public func bindSeenComments(key: String) {
    guard seenKey != key else { return }
    seenKey = key
    seenCommentIDs = Set(defaults.stringArray(forKey: key) ?? [])
  }

  /// Marks a comment seen on this device, which takes it out of the Inbox.
  /// - Parameter id: The comment.
  public func markCommentSeen(_ id: String) {
    guard seenCommentIDs.insert(id).inserted, let seenKey else { return }
    defaults.set(seenCommentIDs.sorted(), forKey: seenKey)
  }

  /// Sends `text` to `session` from the Inbox. A failure keeps the draft with the caller.
  /// - Parameters:
  ///   - text: The reply.
  ///   - session: The session, as listed.
  /// - Returns: Whether it was sent.
  @discardableResult
  public func reply(_ text: String, to session: SessionSummary) async -> Bool {
    if case .sending = replies[session.id] { return false }
    replies[session.id] = .sending
    do {
      _ = try await core.sendReply(sessionId: session.id, text: text)
      replies[session.id] = .sent(since: session.updatedAt)
      return true
    } catch {
      replies[session.id] = .failed(coreError(error))
      return false
    }
  }

  /// Forgets `sessionID`'s reply state: the user edited the draft, marked it read, or the
  /// agent answered.
  /// - Parameter sessionID: The session.
  public func clearReply(_ sessionID: String) {
    if replies[sessionID] != nil { replies[sessionID] = nil }
  }

  /// Settles sent replies whose session has moved on: new activity and no turn running.
  /// - Parameter sessions: The session list.
  public func settleReplies(_ sessions: [String: SessionSummary]) {
    for (id, state) in replies {
      guard case .sent(let since) = state, let session = sessions[id] else { continue }
      if session.updatedAt > since, session.status != .running { replies[id] = nil }
    }
  }
}
