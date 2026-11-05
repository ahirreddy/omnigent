import Foundation
import Observation
import Testing

@testable import OmnigentUIComponents

@Suite("Transcript rows paced while a reply streams")
struct TranscriptRowsPacerTests {
  @Observable
  final class Store {
    var rows: [Row] = []
    var revision: UInt64 = 0

    func append(_ text: String) {
      rows.append(Row(id: "r\(rows.count)", role: .assistant, text: text))
      revision += 1
    }
  }

  private static func reader(_ store: Store) -> LiveTranscriptRows {
    LiveTranscriptRows { (store.rows, store.revision) }
  }

  private static func settle() async throws {
    try await Task.sleep(for: .milliseconds(300))
  }

  @Test("A burst of deltas reaches the transcript as one update with the latest rows")
  func coalescesBursts() async throws {
    let store = Store()
    let pacer = TranscriptRowsPacer(interval: .milliseconds(40))
    #expect(pacer.rows(from: Self.reader(store), isShown: true).revision == 0)
    for index in 0..<5 { store.append("delta \(index)") }
    try await Self.settle()
    #expect(pacer.published == 1)
    let shown = pacer.rows(from: Self.reader(store), isShown: true)
    #expect(shown.revision == 5)
    #expect(shown.rows.count == 5)
    store.append("later")
    try await Self.settle()
    #expect(pacer.published == 2, "a change after a quiet spell is its own update")
  }

  @Test("A hidden transcript keeps its rows and catches up when it shows again")
  func pausesWhileHidden() async throws {
    let store = Store()
    let pacer = TranscriptRowsPacer(interval: .milliseconds(40))
    _ = pacer.rows(from: Self.reader(store), isShown: true)
    _ = pacer.rows(from: Self.reader(store), isShown: false)
    store.append("while hidden")
    store.append("still hidden")
    try await Self.settle()
    #expect(pacer.published == 0)
    #expect(pacer.rows(from: Self.reader(store), isShown: true).revision == 0)
    try await Self.settle()
    #expect(pacer.published == 1)
    #expect(pacer.rows(from: Self.reader(store), isShown: true).revision == 2)
  }
}
