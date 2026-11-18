import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Synchronization
import Testing

@testable import OmnigentStores

nonisolated private let prURL = "https://github.com/o/r/pull/7"
nonisolated private let github = "/v1/sessions/conv_a/resources/github"
nonisolated private let stored = "/v1/sessions/conv_a/pull-requests"

nonisolated private func linked(_ state: String) -> String {
  #"""
  {"object":"list","data":[{"url":"https://github.com/o/r/pull/7","host":"github.com",
   "repository":"o/r","number":7,"title":"Fix","relationship":"created","state":"\#(state)"}],
   "has_more":false,"synced":true}
  """#
}

/// The open PR as the web's tests shape it: set up, checks `pending` of `total`.
nonisolated private func info(
  state: String = "OPEN", pending: Int = 1, total: Int = 2, head: String = "abc",
  tracking: Bool = false
) -> String {
  #"""
  {"object":"session.github.info","available":true,"branch":"fix",
   "repo":{"name_with_owner":"o/r"},"auth":{"authenticated":true},
   "selected_pr_url":"\#(prURL)","tracking_available":\#(tracking),
   "pr":{"number":7,"title":"Fix","state":"\#(state)","url":"\#(prURL)","head_sha":"\#(head)",
         "checks":{"passing":\#(total - pending),"failing":0,"pending":\#(pending),
                   "total":\#(total)}}}
  """#
}

nonisolated private let hostOffline =
  #"{"error":{"code":"runner_unavailable","message":"The runner is not connected."}}"#

/// A poll timer the test fires by hand: each wait records its duration and blocks until
/// ``fire()``, or until its task is cancelled.
nonisolated private final class ManualPollTimer: PullRequestPollTimer {
  private struct Waiter {
    let id: Int
    let duration: Duration
    let continuation: CheckedContinuation<Void, Never>
  }

  private struct State {
    var nextID = 0
    var waiting: [Waiter] = []
    var cancelled: Set<Int> = []
  }

  private let state = Mutex(State())

  func wait(_ duration: Duration) async {
    let id = state.withLock { state in
      state.nextID += 1
      return state.nextID
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let cancelled = state.withLock { state in
          guard !state.cancelled.contains(id) else { return true }
          state.waiting.append(Waiter(id: id, duration: duration, continuation: continuation))
          return false
        }
        if cancelled { continuation.resume() }
      }
    } onCancel: {
      let waiter = state.withLock { state -> Waiter? in
        guard let index = state.waiting.firstIndex(where: { $0.id == id }) else {
          state.cancelled.insert(id)
          return nil
        }
        return state.waiting.remove(at: index)
      }
      waiter?.continuation.resume()
    }
  }

  /// The waits in flight, oldest first.
  var waiting: [Duration] { state.withLock { $0.waiting.map(\.duration) } }

  /// Ends the oldest wait.
  func fire() {
    let waiter = state.withLock { $0.waiting.isEmpty ? nil : $0.waiting.removeFirst() }
    waiter?.continuation.resume()
  }
}

@MainActor
private func panel(_ server: RouteServer, timer: ManualPollTimer) async throws -> SessionPanelStore
{
  server.route(
    "/v1/info",
    .json(#"{"single_user":true,"accounts_enabled":false,"session_pull_requests":true}"#))
  server.route(stored, .json(linked("OPEN")))
  server.route("\(github)/diff", .json(#"{"object":"session.github.pr_diff","patch":""}"#))
  let connection = try await connectedStore(server)
  let core = try #require(connection.core)
  return SessionPanelStore(sessionID: "conv_a", core: core, pollTimer: timer)
}

/// Waits until the poll waits `duration`, the only wait in flight.
@MainActor
private func waits(
  _ timer: ManualPollTimer, _ duration: Duration?,
  sourceLocation: SourceLocation = #_sourceLocation
) async throws {
  let expected = duration.map { [$0] } ?? []
  try await eventually("a wait of \(String(describing: duration))", sourceLocation: sourceLocation)
  {
    timer.waiting == expected
  }
}

/// Waits until the poll found nothing to watch and stopped waiting.
@MainActor
private func rests(
  _ store: SessionPanelStore, _ timer: ManualPollTimer,
  sourceLocation: SourceLocation = #_sourceLocation
) async throws {
  try await eventually("the poll rests", sourceLocation: sourceLocation) {
    store.pollRests && timer.waiting.isEmpty
  }
}

/// Waits until the last watcher left and the poll stopped.
@MainActor
private func stops(
  _ store: SessionPanelStore, _ timer: ManualPollTimer,
  sourceLocation: SourceLocation = #_sourceLocation
) async throws {
  try await eventually("the poll stops", sourceLocation: sourceLocation) {
    store.watchers.isEmpty && store.pollTask == nil && timer.waiting.isEmpty
  }
}

private func reads(_ server: RouteServer, _ path: String = github) -> Int {
  server.requests(to: path, method: "GET").count
}

/// The web's poll rules for the open PR, the list and the composer: how often each reads, when
/// they rest, the backoff while the host is offline, and that hidden watchers stop.
@MainActor
@Suite("Polling the session's pull requests", .timeLimit(.minutes(1)))
struct PullRequestPollingTests {
  @Test("The open PR polls every 5 seconds while checks run and rests once they settle")
  func openPullRequestPolls() async throws {
    let (server, timer) = (RouteServer(), ManualPollTimer())
    server.route(github, .json(info(pending: 1)))
    let store = try await panel(server, timer: timer)
    await store.showPullRequest(prURL)
    let watching = Task { await store.watch(.panel) }
    try await waits(timer, .seconds(5))
    let (before, patches) = (reads(server), reads(server, "\(github)/diff"))

    timer.fire()
    try await waits(timer, .seconds(5))
    #expect(reads(server) == before + 1)
    #expect(reads(server, "\(github)/diff") == patches, "the head did not move")

    server.route(github, .json(info(pending: 0, head: "def")))
    timer.fire()
    try await rests(store, timer)
    #expect(reads(server, "\(github)/diff") == patches + 1, "a new head re-reads the patch")
    #expect(store.detail.value?.pullRequest?.checks.pending == 0)

    // A read from outside the poll (Refresh) that finds checks running again restarts it.
    server.route(github, .json(info(pending: 1, head: "def")))
    await store.reloadDetail()
    try await waits(timer, .seconds(5))
    watching.cancel()
    try await stops(store, timer)
  }

  @Test("A host that links PRs polls the open panel every 10 seconds, even once it settles")
  func trackingHostPolls() async throws {
    let (server, timer) = (RouteServer(), ManualPollTimer())
    server.route(github, .json(info(state: "MERGED", pending: 0, tracking: true)))
    let store = try await panel(server, timer: timer)
    await store.showPullRequest(prURL)
    let watching = Task { await store.watch(.panel) }
    try await waits(timer, .seconds(10))
    timer.fire()
    try await waits(timer, .seconds(10))
    watching.cancel()
  }

  @Test("The composer polls linked PRs every 30 seconds while one is open, then rests")
  func composerPolls() async throws {
    let (server, timer) = (RouteServer(), ManualPollTimer())
    server.route(github, .json(info(pending: 1)))
    let store = try await panel(server, timer: timer)
    await store.reloadPullRequests()
    let watching = Task { await store.watch(.composer) }
    try await waits(timer, .seconds(30))
    let (before, live) = (reads(server, stored), reads(server))

    server.route(github, .json(info(state: "MERGED", pending: 0)))
    timer.fire()
    try await rests(store, timer)
    #expect(reads(server, stored) == before + 1)
    #expect(reads(server) == live + 1)
    #expect(store.liveConditions[prURL] == .merged, "every linked PR is merged")
    watching.cancel()
  }

  @Test("The panel and the composer share one poll at the shortest cadence")
  func watchersShareOnePoll() async throws {
    let (server, timer) = (RouteServer(), ManualPollTimer())
    server.route(github, .json(info(pending: 1)))
    let store = try await panel(server, timer: timer)
    await store.reloadPullRequests()
    await store.showPullRequest(prURL)
    let composer = Task { await store.watch(.composer) }
    let panelWatch = Task { await store.watch(.panel) }
    try await eventually("both watch") { store.watchers.count == 2 }
    try await waits(timer, .seconds(5))
    let stores = reads(server, stored)
    for _ in 0..<6 {
      timer.fire()
      try await waits(timer, .seconds(5))
    }
    #expect(reads(server, stored) == stores + 1, "the list's 30 seconds came once")

    panelWatch.cancel()
    try await waits(timer, .seconds(30))
    composer.cancel()
    try await stops(store, timer)
  }

  @Test("A host that is offline backs off to 15 seconds, then the poll rests")
  func hostOfflineBacksOff() async throws {
    let (server, timer) = (RouteServer(), ManualPollTimer())
    server.route(github, .json(hostOffline, status: 503))
    let store = try await panel(server, timer: timer)
    await store.showPullRequest(prURL)
    #expect(store.detail.error?.isHostOffline == true)
    let watching = Task { await store.watch(.panel) }
    let seconds: [Int64] = [1, 2, 4, 8] + Array(repeating: 15, count: 9)
    for delay in seconds {
      try await waits(timer, .seconds(delay))
      timer.fire()
    }
    try await rests(store, timer)

    server.route(github, .json(info(pending: 1)))
    await store.reloadDetail()
    try await waits(timer, .seconds(5))
    watching.cancel()
  }

  @Test("A watcher shown again re-reads first; with no watcher nothing polls")
  func resumedWatcherRereads() async throws {
    let (server, timer) = (RouteServer(), ManualPollTimer())
    server.route(github, .json(info(pending: 1)))
    let store = try await panel(server, timer: timer)
    await store.showPullRequest(prURL)
    try await waits(timer, nil)
    let before = reads(server)

    let watching = Task { await store.watch(.panel, resumed: true) }
    try await waits(timer, .seconds(5))
    #expect(reads(server) == before + 1)
    watching.cancel()
    try await stops(store, timer)
  }
}
