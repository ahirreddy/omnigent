import Foundation
import OmnigentAppUI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppBrowser
@testable import OmnigentBrowser
@testable import OmnigentStores

/// Annotate and Draw from a browser page: the request goes to the window's outbox for the
/// session whose tabs hold the page, worded as the web's message, and the page hears how it went.
@MainActor
struct BrowserTabHostDesignTests {
  @Test func aPagesRequestGoesToItsSessionAsTheWebWordsIt() async throws {
    let fixture = try BrowserTabHostTests.Fixture()
    defer { fixture.removeDefaults() }
    let groups = SessionTabGroups()
    let window = UUID()
    fixture.host.attach(window: window, tabs: groups)
    var delivered: [DesignOutboxRequest] = []
    let outbox = DesignRequestOutbox(
      timing: .init(poll: .milliseconds(5), turnStart: .milliseconds(10)),
      isRunning: { _ in false },
      owner: { DesignOutboxOwner(server: "https://agents.example.com", account: "ada") },
      deliver: { delivered.append($0) })
    fixture.host.attachDesignRequests(window: window, outbox: outbox)
    let page = fixture.host.makePage(url: URL(string: "https://app.example.test/a?secret=1"))
    groups.group("conv_a").open(.browser(browserID: page.id), browserState: page.state)
    let model = try #require(fixture.host.page(page.id))
    #expect(fixture.environment.designRequestSender != nil)

    let element = BrowserDesignElement(tag: "h1", text: "Welcome")
    try fixture.host.queueDesignRequest(
      BrowserDesignRequest(
        content: .element(element, request: "Bigger"), pageURL: model.url,
        screenshotPNG: Data([1])),
      from: model)
    try await waitFor { !delivered.isEmpty }
    let sent = try #require(delivered.first)
    #expect(sent.sessionID == "conv_a" && sent.tool == .annotate)
    #expect(sent.label == "Annotate h1 \"Welcome\"")
    #expect(sent.text.hasPrefix("Bigger\n\n---\n[Design Mode \u{2014} modify this element"))
    #expect(sent.files.map(\.name) == ["design-element.png"])
    try await waitFor { model.designTools.notice?.message == DesignRequestOutbox.Copy.sent }

    let drawing = BrowserDesignRequest(
      content: .drawing(note: "", marks: 2), pageURL: model.url, screenshotPNG: Data([2]))
    #expect(DesignRequestMessage.text(drawing).contains("Page: https://app.example.test\n"))
    #expect(DesignRequestMessage.files(drawing).first?.name == "design-drawing.png")
    let unshot = BrowserDesignRequest(
      content: .element(element, request: "Bigger"), pageURL: nil, screenshotPNG: nil)
    #expect(DesignRequestMessage.text(unshot).contains(DesignToolPrompt.noScreenshotLine))
    #expect(DesignRequestMessage.files(unshot).isEmpty)
  }

  @Test func aPageInNoSessionsTabsCantSend() throws {
    let fixture = try BrowserTabHostTests.Fixture()
    defer { fixture.removeDefaults() }
    let page = fixture.host.makePage(url: URL(string: "https://app.example.test/a"))
    let model = try #require(fixture.host.page(page.id))
    let request = BrowserDesignRequest(
      content: .drawing(note: "x", marks: 1), pageURL: nil, screenshotPNG: Data([1]))
    #expect(throws: BrowserError.self) { try fixture.host.queueDesignRequest(request, from: model) }
    let groups = SessionTabGroups()
    let window = UUID()
    fixture.host.attach(window: window, tabs: groups)
    groups.group("conv_a").open(.browser(browserID: page.id), browserState: page.state)
    // A window without an outbox (a host that offers none) can't send either.
    #expect(throws: BrowserError.self) { try fixture.host.queueDesignRequest(request, from: model) }
  }

  private func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
      guard ContinuousClock.now < deadline else {
        Issue.record("the condition never held")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
