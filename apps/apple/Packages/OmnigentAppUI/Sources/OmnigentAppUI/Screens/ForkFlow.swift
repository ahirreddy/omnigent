import Observation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// One conversation's fork sheet: what it copies, the request through a ``ForkStore``, and
/// opening the fork once it exists.
@Observable
final class ForkFlow {
  /// What the open sheet copies; `nil` when no sheet shows.
  private(set) var context: ForkContext?
  private var store: ForkStore?

  /// The sheet's state, while one shows.
  var viewState: ForkViewState? {
    guard let context, let store else { return nil }
    let catalogError: String? =
      if case .failed(let error) = store.catalog { error.message } else { nil }
    // An unacknowledged uncertain fork blocks another until the sheet is dismissed.
    return ForkAdapter.state(
      context: context, plan: store.plan(for: context.source),
      isForking: store.phase == .forking || !store.canFork,
      errorMessage: store.errorMessage ?? catalogError)
  }

  /// Opens the sheet for `context` and loads the agents and hosts it offers.
  /// - Parameters:
  ///   - context: What to copy.
  ///   - makeStore: Creates the store on first use.
  func begin(_ context: ForkContext, makeStore: () -> ForkStore?) async {
    guard let store = store ?? makeStore() else { return }
    self.store = store
    store.reset()
    self.context = context
    await store.loadCatalog()
  }

  /// Forks with the sheet's choices. Once the fork exists the sheet closes and `open` shows it;
  /// a start that failed is passed to `report`. Other failures stay in the sheet.
  /// - Parameters:
  ///   - agentID: The chosen agent.
  ///   - directory: The chosen directory.
  ///   - start: Whether to start the fork on the source's host.
  ///   - open: Opens a session.
  ///   - report: Shows a failure outside the sheet.
  func fork(
    agentID: String, directory: String, start: Bool, open: @MainActor (String) -> Void,
    report: @MainActor (String) -> Void
  ) async {
    guard let context, let store else { return }
    let plan = store.plan(for: context.source)
    let request = ForkAdapter.request(
      context: context, plan: plan, agentID: agentID, directory: directory, start: start)
    guard let sessionID = await store.fork(request) else { return }
    self.context = nil
    open(sessionID)
    if case .forked(_, let launchError?) = store.phase {
      report("The fork was created but did not start: \(launchError.message)")
    }
  }

  /// Closes the sheet. An uncertain fork's warning has been seen, so another may start.
  func cancel() {
    // A sheet binding can write `nil` while nothing shows; writing state then would loop.
    guard context != nil else { return }
    context = nil
    store?.acknowledgeUncertain()
    store?.reset()
  }
}
