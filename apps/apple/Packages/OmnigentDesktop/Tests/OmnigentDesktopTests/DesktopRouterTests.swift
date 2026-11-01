import Foundation
import Testing

@testable import OmnigentDesktop

private struct FakeAcknowledger: DeepLinkAcknowledging {
  enum Answer: Sendable {
    case accept
    case decline
    case fail
  }

  let answer: Answer

  func acknowledge(_ acknowledgment: DeepLinkAcknowledgment)
    async throws(DeepLinkAcknowledgmentError) -> Bool
  {
    await Task.yield()
    switch answer {
    case .accept: return true
    case .decline: return false
    case .fail: throw .transport(URLError(.cannotConnectToHost))
    }
  }
}

@MainActor
private final class IssueLog {
  var issues: [DesktopIssue] = []
}

@MainActor
private final class Harness {
  let registry: ServerWindowRegistry
  let router: DesktopRouter
  var opened: [ServerWindowID] = []
  private let log = IssueLog()
  var consentRequests: [ServerOrigin] = []
  var consentAnswer = true
  var remembered: [URL] = []

  init(acknowledger: FakeAcknowledger.Answer = .accept, known: [URL] = []) {
    let log = log
    registry = ServerWindowRegistry { log.issues.append($0) }
    router = DesktopRouter(
      registry: registry, acknowledger: FakeAcknowledger(answer: acknowledger),
      reportIssue: { log.issues.append($0) })
    router.knownServers = { known }
    router.rememberServer = { [weak self] in self?.remembered.append($0) }
    router.confirmUnknownServer = { [weak self] origin in
      guard let self else { return false }
      consentRequests.append(origin)
      return consentAnswer
    }
  }

  var issues: [DesktopIssue] { log.issues }

  func attach() {
    router.attachWindowOpener { [weak self] in self?.opened.append($0) }
  }

  func open(_ raw: String) async throws {
    router.open([try url(raw)])
    await router.drainTask?.value
  }
}

@Suite("Desktop router")
@MainActor
struct DesktopRouterTests {
  static let token = String(repeating: "b", count: 64)

  @Test("queues links until a window can open others")
  func coldStart() async throws {
    let harness = Harness(known: [try url("http://localhost:8000")])
    try await harness.open("omnigent://localhost:8000/c/c1")
    #expect(harness.opened.isEmpty)
    guard case .awaitingWindowOpener(pending: 1) = harness.issues.first else {
      Issue.record("expected awaitingWindowOpener, got \(harness.issues)")
      return
    }
    harness.attach()
    await harness.router.drainTask?.value
    let opened = try #require(harness.opened.first)
    #expect(opened.serverURL == (try url("http://localhost:8000")))
    #expect(harness.registry.pendingRoute(for: opened.instance) == .conversation(sessionID: "c1"))
  }

  @Test("navigates an open window on the server and brings it to the front")
  func existingWindow() async throws {
    let harness = Harness()
    let window = ServerWindowID.newWindow(serverURL: try url("https://ws.example.com/ml/omnigents"))
    harness.registry.update(window, isReady: true, viewedSessionID: nil, unreadCount: 0)
    harness.attach()
    try await harness.open("omnigent://ws.example.com/c/c9")
    #expect(harness.opened == [window])
    #expect(
      harness.registry.takePendingRoute(for: window.instance) == .conversation(sessionID: "c9"))
    #expect(harness.consentRequests.isEmpty)
  }

  @Test("opens a known server with its recorded mount path")
  func knownServer() async throws {
    let harness = Harness(known: [
      try url("https://ws.example.com/ml/omnigents"), try url("https://ws.example.com/other"),
    ])
    harness.attach()
    try await harness.open("omnigent://ws.example.com/")
    #expect(harness.opened.map(\.serverURL) == [try url("https://ws.example.com/ml/omnigents")])
    #expect(harness.consentRequests.isEmpty)
  }

  @Test("asks before opening a never-used server and remembers it")
  func consentAccepted() async throws {
    let harness = Harness()
    harness.attach()
    try await harness.open("omnigent://new.example.com/c/c1")
    #expect(harness.consentRequests == [try ServerOrigin(serialized: "https://new.example.com")])
    #expect(harness.remembered == [try url("https://new.example.com")])
    #expect(harness.opened.map(\.serverURL) == [try url("https://new.example.com")])
  }

  @Test("declined consent opens nothing and is reported")
  func consentDeclined() async throws {
    let harness = Harness()
    harness.consentAnswer = false
    harness.attach()
    try await harness.open("omnigent://new.example.com/c/c1")
    #expect(harness.opened.isEmpty)
    #expect(harness.remembered.isEmpty)
    guard case .consentDeclined = harness.issues.last else {
      Issue.record("expected consentDeclined, got \(harness.issues)")
      return
    }
  }

  @Test("a CLI link opens only after the CLI acknowledges it")
  func acknowledgment() async throws {
    let accepted = Harness(acknowledger: .accept, known: [try url("http://localhost:6767")])
    accepted.attach()
    try await accepted.open("omnigent://localhost:6767/?desktop_ack=4242:\(Self.token)")
    #expect(accepted.opened.count == 1)

    for answer in [FakeAcknowledger.Answer.decline, .fail] {
      let harness = Harness(acknowledger: answer, known: [try url("http://localhost:6767")])
      harness.attach()
      try await harness.open("omnigent://localhost:6767/?desktop_ack=4242:\(Self.token)")
      #expect(harness.opened.isEmpty)
      switch (answer, harness.issues.last) {
      case (.decline, .acknowledgmentDeclined), (.fail, .acknowledgmentFailed): break
      default: Issue.record("unexpected issues \(harness.issues) for \(answer)")
      }
    }
  }

  @Test("unsupported URLs are reported and dropped")
  func rejected() async throws {
    let harness = Harness()
    harness.attach()
    try await harness.open("omnigent://localhost/settings")
    #expect(harness.opened.isEmpty)
    guard case .deepLinkRejected(_, .unsupportedPath("/settings")) = harness.issues.first else {
      Issue.record("expected deepLinkRejected, got \(harness.issues)")
      return
    }
  }

  @Test("notification taps open trusted servers without consent")
  func trustedRoute() async throws {
    let harness = Harness()
    harness.attach()
    let serverURL = try url("https://ws.example.com/ml/omnigents")
    harness.router.open(.conversation(sessionID: "c3"), onServer: serverURL)
    await harness.router.drainTask?.value
    #expect(harness.consentRequests.isEmpty)
    let opened = try #require(harness.opened.first)
    #expect(opened.serverURL == serverURL)
    #expect(harness.registry.pendingRoute(for: opened.instance) == .conversation(sessionID: "c3"))
  }

  @Test("links are handled one at a time, in order")
  func serialized() async throws {
    let harness = Harness(known: [
      try url("https://a.example.com"), try url("https://b.example.com"),
    ])
    harness.attach()
    harness.router.open([
      try url("omnigent://new.example.com/"), try url("omnigent://a.example.com/"),
      try url("omnigent://b.example.com/"),
    ])
    await harness.router.drainTask?.value
    #expect(
      harness.opened.compactMap(\.serverURL?.host) == [
        "new.example.com", "a.example.com", "b.example.com",
      ])
  }
}
