public import Foundation
public import Observation
public import OmnigentCoreFFI

/// Why a row operation did not fit the rows it was applied to.
public struct RowOpMismatch: Error, Equatable, Sendable {
  /// What did not fit.
  public let detail: String
}

/// Applies `ops` to `rows` in order, with the core's reference semantics (`apply_row_ops`):
/// indexes are positions after every earlier op of the set.
/// - Parameters:
///   - ops: The operations.
///   - rows: The rows to patch in place. On failure they keep the ops applied before it.
/// - Throws: ``RowOpMismatch`` for an op that does not fit.
public func applyRowOps(_ ops: [RowOp], to rows: inout [Row]) throws(RowOpMismatch) {
  for operation in ops {
    switch operation {
    case .insert(let index, let row):
      let position = Int(index)
      guard position <= rows.count else {
        throw RowOpMismatch(detail: "insert at \(index) is past \(rows.count) rows")
      }
      rows.insert(row, at: position)
    case .update(let index, let row):
      let position = Int(index)
      guard position < rows.count else {
        throw RowOpMismatch(detail: "update at \(index) is past \(rows.count) rows")
      }
      guard rows[position].id == row.id else {
        throw RowOpMismatch(
          detail: "update at \(index) targets \(rows[position].id), not \(row.id)")
      }
      rows[position] = row
    case .remove(let id):
      guard let position = rows.firstIndex(where: { $0.id == id }) else {
        throw RowOpMismatch(detail: "no row \(id) to remove")
      }
      rows.remove(at: position)
    }
  }
}

/// One open conversation: rows, header, sections and stream state, patched in place from the
/// core's transcript events.
@Observable
public final class ConversationStore {
  /// The session.
  public let sessionID: String
  /// Every row, in order: transcript and activity rows.
  public private(set) var rows: [Row] = []
  /// The session header, once known.
  public private(set) var header: SessionHeader? {
    didSet {
      let online = header?.settings?.hostOnline
      if online == true, online != oldValue?.settings?.hostOnline { composer.hostCameOnline() }
      // A running turn or a reported runner means the runner is back.
      if runnerUnavailable != nil,
        header?.settings?.runnerOnline == true || header?.status == .running
      {
        runnerUnavailable = nil
      }
    }
  }
  /// Session sections (usage, plan, changed files, ...).
  public private(set) var sections: [EventSection] = []
  /// The revision of the applied state.
  public private(set) var revision: UInt64 = 0
  /// The stream's state.
  public private(set) var link: LinkState = .idle
  /// History has loaded; sends are possible.
  public private(set) var isHydrated = false
  /// The latest readable turn failure.
  public private(set) var lastFailure: String?
  /// Failures in this session, newest last. Never dropped silently.
  public private(set) var errors: [CoreError] = []
  /// The last terminal or browser read found the runner offline: the agent is asleep until a
  /// message relaunches it. A panel state, not a session error.
  public private(set) var runnerUnavailable: CoreError?
  /// The core closed the session (removed or access lost).
  public private(set) var isClosed = false
  /// The session the conversation continues in, when superseded.
  public private(set) var supersededBy: String?
  /// When the running turn started and how long finished turns worked, for the turns this
  /// store saw start.
  public private(set) var turnTimer = TurnTimer()
  /// What the status line needs from the rows. Changes only when those facts do, so views that
  /// read it do not re-render for every streamed delta.
  public private(set) var transcriptDigest = TranscriptDigest(rows: [])
  /// Decision cards.
  public let decisions: DecisionStore
  /// The composer.
  public let composer: ComposerStore
  /// The Add (+) menu's side chat, plan mode and goal.
  public let tools: SessionToolsStore
  /// Older history exists above ``rows``; ``loadOlderHistory()`` reads the next page.
  public private(set) var hasOlderHistory = false
  /// A page of older history is loading.
  public private(set) var isLoadingOlderHistory = false
  /// The agent's MCP servers and the session's policies, once ``loadAgentInfo(agentID:)`` read
  /// them.
  public private(set) var agentInfo: AgentInfo?

  let core: ClientCore
  private let listStatus: ListStatusExpectation

  init(
    sessionID: String, core: ClientCore,
    listStatus: ListStatusExpectation = ListStatusExpectation()
  ) {
    self.sessionID = sessionID
    self.core = core
    self.listStatus = listStatus
    decisions = DecisionStore(sessionID: sessionID, core: core, listStatus: listStatus)
    composer = ComposerStore(sessionID: sessionID, core: core)
    tools = SessionToolsStore(sessionID: sessionID, core: core)
    composer.conversationFacts = { [weak self] in self?.composerFacts }
  }

  /// What the composer's `/context`, `/mcp` and held sends read. Read on demand, never while
  /// rendering.
  private var composerFacts: ConversationFacts {
    let usage = sections.first { $0.id == "usage" }
    func number(_ id: String) -> UInt64? {
      usage?.details.first { $0.id == id }.flatMap { UInt64($0.text) }
    }
    return ConversationFacts(
      tokensUsed: number("context_tokens"), contextWindow: number("context_window"),
      items: transcriptRows.count, mcpServers: agentInfo?.tools ?? [],
      agentLoaded: agentInfo != nil, isRunning: isRunning,
      hostOnline: header?.settings?.hostOnline ?? false)
  }

  /// Rows that belong in the transcript.
  public var transcriptRows: [Row] { rows.filter { !$0.isActivityOnly } }

  /// Routine bookkeeping rows for an activity drawer.
  public var activityRows: [Row] { rows.filter(\.isActivityOnly) }

  /// Whether a turn is running.
  public var isRunning: Bool { header?.status == .running }

  /// Stops the active turn. The session list shows it idle at once (see
  /// ``SessionListStore/expect(_:for:)``); a failure reverts that and is kept in ``errors``.
  public func interrupt() async {
    let expectation = listStatus.expect(.idle)
    do {
      try await core.interrupt(sessionId: sessionID)
    } catch {
      expectation.withdraw()
      record(coreError(error))
    }
  }

  /// The session's metadata and full history as JSON Lines, in the web's export format.
  /// - Returns: The file's text.
  /// - Throws: The core's read error.
  public func exportTranscript() async throws(CoreError) -> String {
    do {
      return try await core.exportTranscript(sessionId: sessionID)
    } catch {
      throw coreError(error)
    }
  }

  /// The bytes of one of the session's uploaded files, for an inline preview.
  /// - Parameter reference: The attachment's file id, or a path or URL of the session's file.
  /// - Returns: The file's bytes.
  /// - Throws: The core's error: not a session file, a refused type or size, or the read error.
  public func attachmentPreview(reference: String) async throws(CoreError) -> Data {
    do {
      return try await core.attachmentPreview(sessionId: sessionID, reference: reference).data
    } catch {
      throw coreError(error)
    }
  }

  /// Recovers the failed turn as `recovery` says (the error card's Retry). A failure, or a
  /// resume that found the runner already connected, is kept in ``errors``.
  /// - Parameter recovery: Continue the turn, or resume the session.
  public func recoverTurn(_ recovery: FailureRecovery) async {
    do {
      let recovered = try await core.recoverTurn(sessionId: sessionID, recovery: recovery)
      if !recovered {
        let message =
          recovery == .resume
          ? "The session is already connected; nothing was recovered."
          : "The retry was not accepted."
        record(.InvalidState(message: message))
      }
    } catch {
      record(coreError(error))
    }
  }

  /// Reads the Agent info of this session's agent `agentID`. A failure is kept in ``errors``.
  /// - Parameter agentID: The session's agent.
  public func loadAgentInfo(agentID: String) async {
    do {
      let info = try await core.agentInfo(sessionId: sessionID, agentId: agentID)
      if info != agentInfo { agentInfo = info }
    } catch {
      record(coreError(error))
    }
  }

  /// Reads the page of history above ``rows``; it arrives as rows inserted at the top. Does
  /// nothing without older history or while a page is loading.
  public func loadOlderHistory() {
    guard hasOlderHistory, !isLoadingOlderHistory else { return }
    core.loadOlderHistory(sessionId: sessionID)
  }

  /// Clears ``errors`` after the user has seen them.
  public func dismissErrors() {
    errors = []
  }

  func reset(
    revision: UInt64, rows: [Row], header: SessionHeader?, sections: [EventSection],
    decisions cards: [DecisionCard]
  ) {
    self.revision = revision
    self.rows = rows
    let header = Self.known(header)
    if header != self.header { self.header = header }
    if sections != self.sections { self.sections = sections }
    decisions.replace(cards)
    timeTurn(observed: false)
    digestRows()
  }

  func apply(revision: UInt64, change: TranscriptChange) {
    do throws(RowOpMismatch) {
      try applyRowOps(change.rows, to: &rows)
    } catch {
      // The store diverged from the core; reopening asks the core for a full reset.
      record(.RowOps(message: error.detail))
      core.openSession(sessionId: sessionID)
      return
    }
    // Setting an observed property notifies even when the value is unchanged.
    if let header = Self.known(change.header), header != self.header { self.header = header }
    if let sections = change.sections, sections != self.sections { self.sections = sections }
    self.revision = revision
    timeTurn(observed: true)
    digestRows()
  }

  /// The core's stand-in header, shown until the server's metadata loads, is no header: the
  /// session is still loading, not an empty read-only one titled "Conversation".
  private static func known(_ header: SessionHeader?) -> SessionHeader? {
    header?.isPlaceholder == true ? nil : header
  }

  private func digestRows() {
    let digest = TranscriptDigest(rows: rows)
    if digest != transcriptDigest { transcriptDigest = digest }
  }

  private func timeTurn(observed: Bool) {
    let running = isRunning
    var timer = turnTimer
    timer.update(isRunning: running, observed: observed, responseIDs: latestTurnResponseIDs())
    if timer != turnTimer { turnTimer = timer }
  }

  /// The response ids of the rows after the last user message.
  private func latestTurnResponseIDs() -> [String] {
    let start = rows.lastIndex { $0.role == .user }.map { $0 + 1 } ?? rows.startIndex
    var seen = Set<String>()
    return rows[start...].compactMap(\.responseId).filter { seen.insert($0).inserted }
  }

  func linkChanged(_ state: LinkState) {
    if state != link { link = state }
    if state != .live, isHydrated { isHydrated = false }
    switch state {
    case .reconnecting(let reason, _, _): record(reason)
    case .failed(let error): record(error)
    default: break
    }
  }

  func hydrated() {
    if !isHydrated { isHydrated = true }
    composer.streamReady()
  }

  func historyPagingChanged(hasOlder: Bool, isLoading: Bool) {
    if hasOlder != hasOlderHistory { hasOlderHistory = hasOlder }
    if isLoading != isLoadingOlderHistory { isLoadingOlderHistory = isLoading }
  }

  func failure(_ message: String) {
    if message != lastFailure { lastFailure = message }
  }

  func closed() {
    if !isClosed { isClosed = true }
    if isHydrated { isHydrated = false }
  }

  func superseded(by target: String) {
    if target != supersededBy { supersededBy = target }
  }

  func record(_ error: CoreError) {
    if error.isRunnerUnavailable {
      if error != runnerUnavailable { runnerUnavailable = error }
      return
    }
    errors.append(error)
    if errors.count > 50 { errors.removeFirst(errors.count - 50) }
  }
}

/// The transcript facts the session status line reads: whether there are rows, whether the last
/// was interrupted, and the latest in-progress tool.
public struct TranscriptDigest: Equatable, Sendable {
  /// No transcript rows yet.
  public var isEmpty: Bool
  /// The last transcript row was interrupted.
  public var lastInterrupted: Bool
  /// The latest in-progress tool's title.
  public var activityTitle: String?

  /// The digest of `rows`.
  /// - Parameter rows: Every row; activity-only rows are skipped.
  public init(rows: [Row]) {
    let transcript = rows.lazy.filter { !$0.isActivityOnly }
    isEmpty = transcript.isEmpty
    lastInterrupted = transcript.last?.interrupted == true
    activityTitle =
      transcript.last { $0.activity?.status == "in_progress" }?.activity?.title
  }
}
