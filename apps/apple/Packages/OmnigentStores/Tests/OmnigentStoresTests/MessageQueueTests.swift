import Foundation
import Testing

@testable import OmnigentStores

@Suite("Composer queue state machine")
struct MessageQueueTests {
  @Test("Messages drain oldest first, one at a time, only while nothing runs")
  func drainOrder() throws {
    var queue = MessageQueue()
    let first = try queue.enqueue("  first  ")
    let second = try queue.enqueue("second")
    #expect(first.text == "first")
    #expect(queue.next(isRunning: true, isBlocked: false) == nil)
    #expect(queue.next(isRunning: false, isBlocked: true) == nil)
    #expect(queue.next(isRunning: false, isBlocked: false)?.id == first.id)
    #expect(try queue.begin(first.id).text == "first")
    #expect(queue.isSending)
    #expect(queue.next(isRunning: false, isBlocked: false) == nil, "one send at a time")
    queue.finish(first.id, failure: nil)
    #expect(queue.items.map(\.id) == [second.id])
    #expect(queue.next(isRunning: false, isBlocked: false)?.id == second.id)
  }

  @Test("A failed message keeps its place and holds the queue until retried or removed")
  func failureHoldsOrder() throws {
    var queue = MessageQueue()
    let first = try queue.enqueue("first")
    try queue.enqueue("second")
    _ = try queue.begin(first.id)
    queue.finish(first.id, failure: "The host is offline.")
    #expect(queue.items.first?.state == .failed("The host is offline."))
    #expect(queue.next(isRunning: false, isBlocked: false) == nil)
    #expect(try queue.begin(first.id).text == "first", "Retry is the user's")
    queue.finish(first.id, failure: nil)
    #expect(queue.items.map(\.text) == ["second"])
  }

  @Test("Edit and remove refuse a message in flight; edit requeues a failure")
  func editAndRemove() throws {
    var queue = MessageQueue()
    let item = try queue.enqueue("draft")
    try queue.edit(item.id, text: "edited")
    #expect(queue.items.first?.text == "edited")
    #expect(throws: MessageQueue.Refusal.empty) { try queue.edit(item.id, text: "  ") }
    _ = try queue.begin(item.id)
    #expect(throws: MessageQueue.Refusal.sending) { try queue.edit(item.id, text: "x") }
    #expect(throws: MessageQueue.Refusal.sending) { try queue.remove(item.id) }
    #expect(throws: MessageQueue.Refusal.sending) { try queue.begin(item.id) }
    queue.finish(item.id, failure: "Refused")
    try queue.edit(item.id, text: "fixed")
    #expect(queue.items.first?.state == .queued)
    try queue.remove(item.id)
    #expect(queue.isEmpty)
    #expect(throws: MessageQueue.Refusal.missing) { try queue.remove(item.id) }
    #expect(throws: MessageQueue.Refusal.empty) { try queue.enqueue("\n") }
  }

  @Test("Files or paths alone are a message, and keep it when its text is cleared")
  func extras() throws {
    var queue = MessageQueue()
    let files = MessageQueue.Extras(
      holdID: 7, files: [MessageQueue.File(name: "shot.png", isImage: true)])
    let item = try queue.enqueue(" ", extras: files)
    #expect(item.text.isEmpty && item.extras == files)
    try queue.edit(item.id, text: "")
    #expect(try queue.begin(item.id).extras.holdID == 7)
    queue.hold("", extras: MessageQueue.Extras(mentions: ["src/"]))
    #expect(queue.items.first?.extras.mentions == ["src/"])
  }

  @Test("Moving keeps every message, as List.onMove reports it")
  func move() throws {
    var queue = MessageQueue()
    for text in ["a", "b", "c"] { try queue.enqueue(text) }
    queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
    #expect(queue.items.map(\.text) == ["b", "c", "a"])
    queue.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
    #expect(queue.items.map(\.text) == ["a", "b", "c"])
    queue.move(fromOffsets: IndexSet([0, 1]), toOffset: 3)
    #expect(queue.items.map(\.text) == ["c", "a", "b"])
  }

  @Test("Messages held for an offline host go first and block the queue until released")
  func hostHold() throws {
    var queue = MessageQueue()
    let queued = try queue.enqueue("queued")
    queue.hold("held first")
    queue.hold(" held second ")
    #expect(queue.items.map(\.text) == ["held first", "held second", "queued"])
    #expect(queue.isHoldingForHost)
    #expect(queue.next(isRunning: false, isBlocked: false) == nil)
    let held = try #require(queue.items.first)
    try queue.edit(held.id, text: "edited")
    #expect(queue.items.first?.state == .waitingForHost, "editing keeps it waiting")
    queue.releaseHeld()
    #expect(!queue.isHoldingForHost)
    #expect(queue.next(isRunning: false, isBlocked: false)?.text == "edited")
    _ = try queue.begin(queued.id)
    queue.waitForHost(queued.id)
    #expect(queue.items.last?.state == .waitingForHost)
  }
}
