import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentStores

/// The outbox as the web's keeps it: on disk per account across relaunches, a day at most, never
/// sent as another account, and with the web's slow note and stall limit.
@MainActor
@Suite("Design request outbox: saved, accounts and slow sends")
struct DesignOutboxSavedTests {
  private typealias Sender = DesignRequestOutboxTests.Sender

  private static let screenshot = DesignOutboxRequest.File(
    name: "design-drawing.png", mediaType: "image/png", data: Data([7, 8, 9]))

  private func folder() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "design-outbox-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  @discardableResult
  private func queue(
    _ outbox: DesignRequestOutbox, _ text: String, session: String = "conv_a",
    outcomes: @escaping (DesignOutboxOutcome) -> Void = { _ in }
  ) -> UUID {
    outbox.queue(
      DesignOutboxRequest.Message(
        tool: .draw, label: "Draw \(text)", text: text, files: [Self.screenshot]),
      to: session, outcome: outcomes)
  }

  @Test("an unsent request comes back after a relaunch, needing a Retry, with its screenshot")
  func restoredAfterRelaunch() async throws {
    let folder = folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    // The app before it closed: its session stays busy, so the request never goes.
    let closed = Sender()
    closed.running = ["conv_a"]
    queue(closed.outbox(storage: DesignOutboxStorage(folder: folder)), "Rounder corners")

    // A relaunch: new storage over the same folder, and a new window's outbox.
    let sender = Sender()
    sender.running = ["conv_a"]
    let after = sender.outbox(storage: DesignOutboxStorage(folder: folder))
    after.restoreSaved()
    let restored = try #require(after.requests.first)
    #expect(restored.text == "Rounder corners" && restored.files == [Self.screenshot])
    #expect(restored.status == .failed(DesignRequestOutbox.Copy.restored, canRetry: true))
    sender.running = []
    try await Task.sleep(for: .milliseconds(40))
    #expect(sender.sent.isEmpty, "a restored request never sends on its own")
    after.retry(restored.id)
    try await eventually("the retry to go") {
      sender.sent == ["Rounder corners"] && after.requests.isEmpty
    }
    let again = sender.outbox(storage: DesignOutboxStorage(folder: folder))
    again.restoreSaved()
    #expect(again.requests.isEmpty, "a sent request is forgotten on disk")
  }

  @Test("a window takes back only its account's requests; a day's are gone, as are another's")
  func perAccountAndExpiry() throws {
    let folder = folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let sender = Sender()
    sender.running = ["conv_a"]
    let storage = DesignOutboxStorage(folder: folder) { now }
    let ada = sender.outbox(storage: storage, now: { now })
    queue(ada, "Old")
    now += 3_600
    sender.signedIn = DesignRequestOutboxTests.grace
    let grace = sender.outbox(storage: storage, now: { now })
    queue(grace, "Grace's")
    let elsewhere = DesignOutboxOwner(server: "https://other.example.org", account: "ada")
    sender.signedIn = elsewhere
    queue(sender.outbox(storage: storage, now: { now }), "Elsewhere")

    // Relaunched a day later as Ada: hers expired, Grace's on this server go, the other stays.
    now += DesignOutboxStorage.lifetime
    sender.signedIn = DesignRequestOutboxTests.ada
    let relaunched = sender.outbox(
      storage: DesignOutboxStorage(folder: folder) { now }, now: { now })
    relaunched.restoreSaved()
    #expect(relaunched.requests.isEmpty)
    sender.signedIn = elsewhere
    let other = sender.outbox(storage: DesignOutboxStorage(folder: folder) { now }, now: { now })
    other.restoreSaved()
    #expect(other.requests.map(\.text) == ["Elsewhere"])
    sender.signedIn = DesignRequestOutboxTests.grace
    let gone = sender.outbox(storage: DesignOutboxStorage(folder: folder) { now }, now: { now })
    gone.restoreSaved()
    #expect(gone.requests.isEmpty, "Grace's was deleted when Ada's window restored")
  }

  @Test("a request isn't sent as another account; signing back in, Retry sends it")
  func accountChanged() async throws {
    let sender = Sender()
    sender.running = ["conv_a"]
    let outbox = sender.outbox()
    var outcomes: [DesignOutboxOutcome] = []
    let id = queue(outbox, "Bigger") { outcomes.append($0) }
    sender.signedIn = DesignRequestOutboxTests.grace
    sender.running = []
    try await eventually("the refusal") { !outcomes.isEmpty }
    #expect(outcomes == [.failed(DesignRequestOutbox.Copy.accountChanged)])
    #expect(sender.sent.isEmpty)
    sender.signedIn = DesignRequestOutboxTests.ada
    outbox.retry(id)
    try await eventually("the retry to go") { sender.sent == ["Bigger"] }
  }

  @Test("a slow send says so; one that never answers stops holding the session's next")
  func slowAndStalled() async throws {
    let sender = Sender()
    sender.hangs = true
    let outbox = sender.outbox(slow: .milliseconds(20), stalled: .milliseconds(80))
    var outcomes: [DesignOutboxOutcome] = []
    let first = queue(outbox, "First") { outcomes.append($0) }
    queue(outbox, "Second")
    try await eventually("the slow note") { outbox.requests.first?.isSlow == true }
    #expect(outbox.requests.first?.status == .sending)
    try await eventually("the give-up") { !outcomes.isEmpty }
    #expect(outcomes == [.failed(DesignRequestOutbox.Copy.stalled)])
    #expect(
      outbox.requests.first?.status
        == .failed(DesignRequestOutbox.Copy.stalled, canRetry: true))
    #expect(outbox.requests.first?.isSlow == false)
    sender.hangs = false
    try await eventually("the next one to go") {
      sender.sent == ["Second"] && outbox.requests.count == 1
    }
    outbox.remove(first)
    #expect(outbox.requests.isEmpty)
  }
}
