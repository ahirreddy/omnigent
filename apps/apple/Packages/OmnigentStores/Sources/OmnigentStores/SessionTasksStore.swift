public import Observation
public import OmnigentCoreFFI

/// One session's journal for the Tasks tab (web `useSessionJournal`): read once when the tab
/// needs it, kept current by the entries the stream pushes, and caught up after the stream was
/// down. Where the tasks stand is the core's (`tasksView`).
@Observable
public final class SessionTasksStore {
  /// Where the journal read stands.
  public enum Journal: Equatable {
    /// Not read yet, nor whether the server keeps journals.
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
  /// The plan's latest Stop pressed here.
  public private(set) var planStop: PlanStop?

  private let core: ClientCore
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var catchingUp = false
  @ObservationIgnored private var stopCount = 0
  @ObservationIgnored private var settlement = PlanStopSettlement()

  init(sessionID: String, core: ClientCore) {
    self.sessionID = sessionID
    self.core = core
  }

  /// The entries read, oldest first; none until the journal is read.
  public var entries: [JournalEntry] {
    if case .loaded(let entries) = journal { return entries }
    return []
  }

  /// Learns whether the server keeps journals, then reads this one; once, until a failure.
  public func load() async {
    guard journal == .idle else { return }
    await start()
  }

  /// Reads the journal again, after a failure.
  public func retry() async {
    await start()
  }

  /// Asks the server whether it keeps journals (`PanelFeatures.sessionJournal`) and reads this
  /// one when it does. The journal stays idle meanwhile, so a server without them shows no tab.
  private func start() async {
    generation += 1
    let current = generation
    let features: PanelFeatures
    do {
      features = try await core.panelFeatures()
    } catch {
      if current == generation { journal = .failed(coreError(error)) }
      return
    }
    guard current == generation else { return }
    if features.sessionJournal {
      await read()
    } else if journal != .unsupported {
      journal = .unsupported
    }
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

/// The plan's Stop: "Stopping…" from the press until the session stops (web `planStops`).
extension SessionTasksStore {
  /// Starts a Stop, before its message goes out.
  /// - Parameter latest: The transcript's latest request now.
  /// - Returns: The Stop, for ``planStopDelivered(_:taken:)``.
  public func beginPlanStop(latest: LatestRequest?) -> PlanStop {
    stopCount += 1
    let stop = PlanStop(id: stopCount, baselineRequestID: latest?.id)
    planStop = stop
    return stop
  }

  /// The stop message went out (`taken`), or didn't, which brings Stop back.
  public func planStopDelivered(_ stop: PlanStop, taken: Bool) {
    guard planStop?.id == stop.id else { return }
    if taken {
      planStop?.sent = true
    } else {
      planStop = nil
    }
  }

  /// Whether the run is stopping; reading it settles a Stop the session is seen to have
  /// finished, or one another request followed.
  /// - Parameters:
  ///   - working: The session works, as the tab reads it.
  ///   - latest: The transcript's latest request.
  /// - Returns: Whether "Stopping…" shows.
  public func isPlanStopping(working: Bool, latest: LatestRequest?) -> Bool {
    settlement.stopping(planStop, working: working, latest: latest)
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
