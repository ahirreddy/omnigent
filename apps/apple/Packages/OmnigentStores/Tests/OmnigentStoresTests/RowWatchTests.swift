import Foundation
import Observation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// Records whether an observed read changed, as a view body depending on it would re-render.
@MainActor
private final class ChangeFlag {
  var changed = false

  init(observing read: () -> Void) {
    withObservationTracking(read) { [weak self] in
      MainActor.assumeIsolated { self?.changed = true }
    }
  }
}

@MainActor
@Suite("Row watches")
struct RowWatchTests {
  private func row(_ id: String, _ text: String = "") -> Row {
    Row(
      id: id, role: .assistant, text: text, isStreaming: false, activity: nil, attachments: [],
      callId: nil, responseId: nil, interrupted: false, author: nil, agent: nil, createdAt: nil,
      isEphemeral: false, isActivityOnly: false)
  }

  private func conversation() throws -> ConversationStore {
    let core = try ClientCore(
      http: FakeHttpTransport(failingWith: .Other(message: "unused")),
      streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(), clock: SystemClock(),
      scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
      entropy: FixedEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
    return ConversationStore(sessionID: "s1", core: core)
  }

  private func change(_ ops: [RowOp]) -> TranscriptChange {
    TranscriptChange(rows: ops, header: nil, sections: nil)
  }

  @Test("a watch follows its row and ignores the others' streamed updates")
  func followsOnlyItsRow() throws {
    let store = try conversation()
    store.reset(revision: 1, rows: [row("q"), row("a")], header: nil, sections: [], decisions: [])
    let watch = store.watchRow("q")
    #expect(watch.row == row("q"))
    #expect(store.watchRow("q") === watch)

    let other = ChangeFlag { _ = watch.row }
    store.apply(revision: 2, change: change([.update(index: 1, row: row("a", "streamed"))]))
    #expect(!other.changed)

    let own = ChangeFlag { _ = watch.row }
    store.apply(revision: 3, change: change([.update(index: 0, row: row("q", "answered"))]))
    #expect(own.changed)
    #expect(watch.row?.text == "answered")
  }

  @Test("a watch reads no rows while observed, and empties when its row goes")
  func doesNotSubscribeToRows() throws {
    let store = try conversation()
    store.reset(revision: 1, rows: [row("a")], header: nil, sections: [], decisions: [])
    let rows = ChangeFlag { _ = store.watchRow("q") }
    store.apply(revision: 2, change: change([.insert(index: 1, row: row("q"))]))
    #expect(!rows.changed)
    #expect(store.watchRow("q").row == row("q"))

    store.apply(revision: 3, change: change([.remove(id: "q")]))
    #expect(store.watchRow("q").row == nil)
    store.reset(revision: 4, rows: [row("q", "back")], header: nil, sections: [], decisions: [])
    #expect(store.watchRow("q").row?.text == "back")
  }
}
