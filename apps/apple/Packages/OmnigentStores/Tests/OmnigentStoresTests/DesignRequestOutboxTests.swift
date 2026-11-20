import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// The Browser design tools' outbox: one request at a time per session, after its turn, and
/// failures kept with why until retried or removed.
@MainActor
@Suite("Design request outbox")
struct DesignRequestOutboxTests {
  /// Records what the outbox sends; a scripted error fails the next send.
  final class Sender {
    var running: Set<String> = []
    var failures: [any Error] = []
    var sent: [String] = []

    func outbox() -> DesignRequestOutbox {
      DesignRequestOutbox(
        timing: .init(poll: .milliseconds(5), turnStart: .milliseconds(30)),
        isRunning: { self.running.contains($0) },
        deliver: { request in
          if !self.failures.isEmpty { throw self.failures.removeFirst() }
          self.sent.append(request.text)
        })
    }
  }

  private static let screenshot = DesignOutboxRequest.File(
    name: "design-element.png", mediaType: "image/png", data: Data([1, 2, 3]))

  private func queue(
    _ outbox: DesignRequestOutbox, _ text: String, session: String = "conv_a",
    outcomes: @escaping (DesignOutboxOutcome) -> Void = { _ in }
  ) -> UUID {
    outbox.queue(
      DesignOutboxRequest.Message(
        tool: .annotate, label: "Annotate \(text)", text: text, files: [Self.screenshot]),
      to: session, outcome: outcomes)
  }

  @Test("a request waits while its session's turn runs, then goes and leaves the list")
  func waitsForTheTurn() async throws {
    let sender = Sender()
    sender.running = ["conv_a"]
    let outbox = sender.outbox()
    var outcomes: [DesignOutboxOutcome] = []
    _ = queue(outbox, "Bigger") { outcomes.append($0) }
    try await Task.sleep(for: .milliseconds(40))
    #expect(sender.sent.isEmpty && outbox.requests(in: "conv_a").first?.status == .waiting)
    sender.running = []
    try await eventually("the request to go") { outcomes == [.sent] }
    #expect(sender.sent == ["Bigger"] && outbox.requests.isEmpty)
  }

  @Test("a session's requests go one at a time, each after the last one's turn")
  func oneAtATime() async throws {
    let sender = Sender()
    let outbox = sender.outbox()
    _ = queue(outbox, "First")
    _ = queue(outbox, "Second")
    _ = queue(outbox, "Elsewhere", session: "conv_b")
    try await eventually("every request to go") { sender.sent.count == 3 }
    let first = try #require(sender.sent.firstIndex(of: "First"))
    #expect(try #require(sender.sent.firstIndex(of: "Second")) > first)
  }

  @Test("a refused request stays with why; Retry sends it, Remove drops it")
  func failures() async throws {
    let sender = Sender()
    sender.failures = [
      CoreError.Session(
        kind: .hostOffline, message: "offline", detail: nil, requiresSignIn: false,
        deliveryUncertain: false)
    ]
    let outbox = sender.outbox()
    var outcomes: [DesignOutboxOutcome] = []
    let id = queue(outbox, "Bigger") { outcomes.append($0) }
    try await eventually("the failure") { !outcomes.isEmpty }
    #expect(outcomes == [.failed(DesignRequestOutbox.Copy.hostOffline)])
    #expect(
      outbox.requests.first?.status
        == .failed(DesignRequestOutbox.Copy.hostOffline, canRetry: true))
    outbox.retry(id)
    try await eventually("the retry to go") { outcomes.count == 2 }
    #expect(outcomes.last == .sent && sender.sent == ["Bigger"])
    sender.failures = [CoreError.InvalidState(message: "nope")]
    let other = queue(outbox, "Other")
    try await eventually("the second failure") {
      outbox.requests.first?.status == .failed("Couldn't send: nope", canRetry: true)
    }
    outbox.remove(other)
    #expect(outbox.requests.isEmpty)
  }

  @Test("why a send failed, worded as the web's outbox")
  func failureWording() {
    let session = { (kind: SessionErrorKind, uncertain: Bool) in
      CoreError.Session(
        kind: kind, message: "detail", detail: nil, requiresSignIn: false,
        deliveryUncertain: uncertain)
    }
    let denied = DesignRequestOutbox.failure(session(.messageDenied, false))
    #expect(denied.message == DesignRequestOutbox.Copy.denied && !denied.canRetry)
    let uncertain = DesignRequestOutbox.failure(session(.transport, true))
    #expect(uncertain.message.hasPrefix("Couldn't tell whether this reached the agent (detail)."))
    #expect(uncertain.canRetry)
  }

  @Test("the outbox sends through the core: the screenshot uploads, then the message posts")
  func sendsThroughTheCore() async throws {
    let live = try await LiveComposer()
    live.acceptMessages()
    live.server.route(
      "/v1/sessions/conv_a/resources/files", method: "POST",
      .json(#"{"id":"file_1","session_id":"conv_a"}"#, status: 201))
    live.composer.text = "my own draft"
    let outbox = DesignRequestOutbox(connection: live.store)
    var outcomes: [DesignOutboxOutcome] = []
    _ = queue(outbox, "Make it red") { outcomes.append($0) }
    try await eventually("the request to be sent") { outcomes == [.sent] }
    #expect(live.postedTexts == ["Make it red"])
    #expect(
      live.server.requests(to: "/v1/sessions/conv_a/resources/files", method: "POST").count == 1)
    #expect(live.composer.text == "my own draft")
  }
}
