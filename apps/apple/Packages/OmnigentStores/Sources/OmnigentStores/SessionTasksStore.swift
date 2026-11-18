public import Observation
public import OmnigentCoreFFI

/// One session's journal for the Tasks tab (web `useSessionJournal`): read once when the tab
/// needs it, kept current by the entries the stream pushes, and caught up after the stream was
/// down. Where the tasks stand is the core's (`tasksView`).
@Observable
public final class SessionTasksStore {
  /// Where the journal read stands.
  public enum Journal: Equatable {
    /// Not read yet.
    case idle
    /// The server keeps no journals; only the agent's own list shows.
    case unsupported
    /// Being read.
    case loading
    /// Read: its entries, in position order.
    case loaded([JournalEntry])
    /// The read failed.
    case failed(CoreError)
  }

  /// The session.
  public let sessionID: String
  /// The journal.
  public private(set) var journal = Journal.idle
  /// A task the tab should scroll to and flash, from its chat marker; the tab clears it.
  public var taskToShow: String?

  private let core: ClientCore
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var catchingUp = false

  init(sessionID: String, core: ClientCore) {
    self.sessionID = sessionID
    self.core = core
  }

  /// The entries read, oldest first; none until the journal is read.
  public var entries: [JournalEntry] {
    if case .loaded(let entries) = journal { return entries }
    return []
  }

  /// Reads the journal when the server keeps one and it was not read yet.
  /// - Parameter supported: The server keeps journals (`PanelFeatures.sessionJournal`).
  public func load(supported: Bool) async {
    guard supported else {
      if journal != .unsupported { journal = .unsupported }
      return
    }
    switch journal {
    case .idle, .unsupported: await read()
    case .loading, .loaded, .failed: break
    }
  }

  /// Reads the journal again, after a failure.
  public func retry() async {
    await read()
  }

  /// The stream pushed an entry: it joins the journal read; one the core could not read, or one
  /// that arrives before the journal was read, has what was missed read.
  /// - Parameter entry: The entry, or `nil` when it could not be read.
  func entryAppended(_ entry: JournalEntry?) async {
    guard case .loaded(let entries) = journal else { return }
    guard let entry else {
      await catchUp()
      return
    }
    journal = .loaded(mergeJournalEntries(entries: entries, added: [entry]))
  }

  /// The stream reopened: reads what it missed while it was down.
  func streamReopened() async {
    await catchUp()
  }

  /// An entry the stream pushed, from the connection's events.
  func journalAppended(_ entry: JournalEntry?) {
    Task { await entryAppended(entry) }
  }

  /// The session's stream changed state; a live one again catches up.
  func linkChanged(_ state: LinkState) {
    guard state == .live else { return }
    Task { await streamReopened() }
  }

  private func read() async {
    generation += 1
    let current = generation
    journal = .loading
    let result: Journal
    do {
      result = .loaded(try await core.sessionJournal(sessionId: sessionID))
    } catch {
      result = .failed(coreError(error))
    }
    if current == generation { journal = result }
  }

  /// Reads the entries after the newest one read; too many missed reads the journal again.
  private func catchUp() async {
    guard !catchingUp, case .loaded(let entries) = journal else { return }
    guard let newest = entries.last else {
      await read()
      return
    }
    catchingUp = true
    defer { catchingUp = false }
    let current = generation
    let missed: [JournalEntry]
    do {
      guard
        let caught = try await core.sessionJournalSince(sessionId: sessionID, afterId: newest.id)
      else {
        // Too many were missed to merge: read the journal again.
        if current == generation { await read() }
        return
      }
      missed = caught
    } catch {
      if current == generation { journal = .failed(coreError(error)) }
      return
    }
    guard current == generation, case .loaded(let known) = journal else { return }
    if !missed.isEmpty { journal = .loaded(mergeJournalEntries(entries: known, added: missed)) }
  }
}

extension ConnectionStore {
  /// Drops the workspace, terminal list and journal of a session that closed.
  func dropStores(of sessionID: String) {
    workspaceStores[sessionID] = nil
    terminalStores[sessionID] = nil
    tasksStores[sessionID] = nil
  }

  /// The Tasks tab's journal of `sessionID`, created on first use.
  /// - Parameter sessionID: The session.
  /// - Returns: The store, or `nil` when the core did not start.
  public func tasks(_ sessionID: String) -> SessionTasksStore? {
    if let existing = tasksStores[sessionID] { return existing }
    guard let core else { return nil }
    let store = SessionTasksStore(sessionID: sessionID, core: core)
    tasksStores[sessionID] = store
    return store
  }
}
