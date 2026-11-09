import Foundation
import Testing

@testable import OmnigentBrowser

/// A location for a button the agent can act on.
private let visibleButton = #"{"x":1,"y":1,"width":5,"height":5,"editable":false,"tag":"button"}"#

@MainActor
@Suite("Agent browser edges", .serialized)
struct AgentBrowserEdgeTests {
  private func request(
    _ action: String, _ args: [String: AgentJSONValue] = [:], conversation: String = "conv_1"
  ) -> AgentBrowserActionRequest {
    AgentBrowserActionRequest(
      actionID: "baction_\(action)", action: action, args: args, conversationID: conversation)
  }

  private func controller(
    _ engine: AgentFakeEngine, timeout: Duration = .seconds(2)
  ) -> AgentBrowserController {
    AgentBrowserController(
      provider: engine, engine: .chromium, urlPolicy: BrowserURLRules(), actionTimeout: timeout)
  }

  /// An engine whose scripts all answer `answer`.
  private func engine(answering answer: String) -> AgentFakeEngine {
    let engine = AgentFakeEngine()
    engine.configure = { $0.respond = { _ in .string(answer) } }
    return engine
  }

  private func failure(
    answering answer: String, _ action: String, _ args: [String: AgentJSONValue]
  ) async -> String {
    let result = await controller(engine(answering: answer)).perform(request(action, args))
    #expect(!result.ok)
    return result.error ?? ""
  }

  @Test("a page's script can answer nonsense, and the agent hears what went wrong")
  func badScriptAnswers() async throws {
    let target: [String: AgentJSONValue] = ["selector": "button"]
    let malformed = await failure(answering: "{", "click", target)
    #expect(malformed.contains("malformed JSON"))
    let hidden = await failure(
      answering: #"{"x":1,"y":1,"width":0,"height":0,"editable":false,"tag":"div"}"#, "click",
      target)
    #expect(hidden.contains("no visible box"))
    let readOnly = await failure(
      answering: visibleButton, "type", ["selector": "button", "text": "x"])
    #expect(readOnly.contains("not a text field"))

    let notJSON = AgentFakeEngine()
    notJSON.configure = { $0.respond = { _ in .bool(true) } }
    let result = await controller(notJSON).perform(request("click", target))
    #expect(result.error?.contains("instead of JSON") == true)
  }

  @Test("pressing a key on an element focuses it first; one that won't focus is an error")
  func pressOnTarget() async throws {
    let focused = engine(answering: #"{"focused":true}"#)
    let agent = controller(focused)
    let pressed = await agent.perform(
      request("press", ["key": "Enter", "modifiers": .array(["Shift"]), "selector": "input"]))
    #expect(pressed.ok)
    #expect(focused.tabs.first?.recorder.presses.first?.0 == .enter)
    #expect(focused.tabs.first?.scripts.contains { $0.contains("el.focus()") } == true)

    let refused = await failure(
      answering: #"{"focused":false}"#, "press", ["key": "Enter", "selector": "input"])
    #expect(refused.contains("did not take focus"))
  }

  @Test("scrolling at an element scrolls at the point the page gives")
  func scrollAtTarget() async throws {
    let engine = engine(answering: visibleButton)
    let result = await controller(engine).perform(
      request("scroll", ["delta_y": .number(40), "selector": "div"]))
    #expect(result.ok)
    let scroll = try #require(engine.tabs.first?.recorder.scrolls.first)
    #expect(scroll.point == CGPoint(x: 1, y: 1))
    #expect(scroll.deltaY == 40)
  }

  @Test("input that starts a load waits for it; one that never ends times out")
  func loadAfterInput() async throws {
    let finishing = engine(answering: visibleButton)
    let configureFinishing = finishing.configure
    finishing.configure = { tab in
      configureFinishing(tab)
      tab.recorder.onClick = { [weak tab] in tab?.load(URL(filePath: "/page")) }
    }
    let loaded = await controller(finishing).perform(request("click", ["selector": "a"]))
    #expect(loaded.ok)

    let stuck = engine(answering: visibleButton)
    let configureStuck = stuck.configure
    stuck.configure = { tab in
      configureStuck(tab)
      tab.recorder.onClick = { [weak tab] in tab?.state.isLoading = true }
    }
    let result = await controller(stuck, timeout: .milliseconds(50)).perform(
      request("click", ["selector": "a"]))
    #expect(result.error?.contains("did not finish loading") == true)
  }

  @Test("cancelling the wait for a page ends it")
  func cancelledWait() async throws {
    let engine = AgentFakeEngine()
    let agent = controller(engine)
    _ = await agent.perform(request("screenshot"))
    let tab = try #require(engine.tabs.first)
    tab.state.isLoading = true
    let wait = Task { () -> String? in
      do throws(BrowserError) {
        _ = try await agent.waitForLoad(tab, expecting: nil, timeout: .seconds(5))
        return nil
      } catch {
        return error.localizedDescription
      }
    }
    try await Task.sleep(for: .milliseconds(20))
    wait.cancel()
    #expect(await wait.value?.contains("cancelled") == true)
  }

  @Test("two actions in one conversation run in the order they came")
  func actionsRunInOrder() async throws {
    let engine = AgentFakeEngine()
    let agent = controller(engine)
    async let first = agent.perform(request("screenshot"))
    async let second = agent.perform(request("screenshot"))
    let results = await [first, second]
    #expect(results.allSatisfy { $0.ok })
    #expect(engine.tabs.count == 1)
  }

  @Test("closing everything closes every conversation's page")
  func closeAll() async throws {
    let engine = AgentFakeEngine()
    let agent = controller(engine)
    _ = await agent.perform(request("screenshot", conversation: "a"))
    _ = await agent.perform(request("screenshot", conversation: "b"))
    agent.closeAll()
    #expect(engine.tabs.allSatisfy { $0.state.isClosed })
    #expect(agent.activeTab(conversationID: "a") == nil)
  }

  @Test("a page closed by itself is dropped; the next action opens another")
  func closedPageIsDropped() async throws {
    let engine = AgentFakeEngine()
    let agent = controller(engine)
    _ = await agent.perform(request("screenshot"))
    engine.tabs.first?.close()
    let result = await agent.perform(request("screenshot"))
    #expect(result.ok)
    #expect(engine.tabs.count == 2)
  }

  @Test("the agent never browses with a person's profile")
  func refusesUserProfiles() async throws {
    let engine = AgentFakeEngine()
    let profile = BrowserUserProfile(name: "Person", color: .blue).browserProfile
    let agent = AgentBrowserController(
      provider: engine, engine: .chromium, urlPolicy: BrowserURLRules(), profile: { _ in profile },
      actionTimeout: .seconds(2))
    let result = await agent.perform(request("screenshot"))
    #expect(!result.ok)
    #expect(result.error?.contains("user's browser profile") == true)
    #expect(engine.tabs.isEmpty)
  }

}

@MainActor
@Suite("Agent browser prompts and strangers", .serialized)
struct AgentBrowserPromptEdgeTests {
  private func request(
    _ action: String, _ args: [String: AgentJSONValue] = [:], conversation: String = "conv_1"
  ) -> AgentBrowserActionRequest {
    AgentBrowserActionRequest(
      actionID: "baction_\(action)", action: action, args: args, conversationID: conversation)
  }

  private func controller(
    _ engine: AgentFakeEngine, timeout: Duration = .seconds(2)
  ) -> AgentBrowserController {
    AgentBrowserController(
      provider: engine, engine: .chromium, urlPolicy: BrowserURLRules(), actionTimeout: timeout)
  }

  @Test("every kind of prompt on an agent page is declined and reported")
  func promptsAreDeclined() async throws {
    let engine = AgentFakeEngine()
    let agent = controller(engine)
    _ = await agent.perform(request("screenshot"))
    let tab = try #require(engine.tabs.first)
    var answers: [String] = []
    let prompts: [BrowserPrompt] = [
      .fileChooser(
        BrowserFileChooserPrompt(
          mode: .open, allowedExtensions: [], allowedMIMETypes: [], suggestedName: ""
        ) { answers.append("files \($0.count)") }),
      .download(
        BrowserDownloadPrompt(
          url: try testURL("https://a.example/f"), suggestedName: "f", mimeType: "", totalBytes: nil
        ) { answers.append("download \($0 == nil)") }),
      .authentication(
        BrowserAuthPrompt(
          space: BrowserProtectionSpace(
            host: "a.example", port: 443, realm: "", scheme: "", isProxy: false, isSecure: true)
        ) { answers.append("auth \($0 == nil)") }),
      .certificateError(
        BrowserCertificatePrompt(
          url: try testURL("https://a.example/"), message: "untrusted", errorCode: 1, subject: "",
          issuer: "", isOverridable: true
        ) { answers.append("certificate \($0)") }),
      .color(BrowserColorPrompt(initialColor: "#000000") { answers.append("color \($0 == nil)") }),
    ]
    for prompt in prompts { agent.tab(tab, didRequest: prompt) }
    #expect(
      answers == ["files 0", "download true", "auth true", "certificate false", "color true"])
    agent.tab(tab, didCancel: prompts[0])
    agent.tab(tab, didBlock: BrowserBlockedPopup(url: nil, reason: "Blocked"))

    let result = await agent.perform(request("screenshot"))
    guard case .array(let events)? = result.data["dialogs"] else {
      Issue.record("no dialogs in \(result.data)")
      return
    }
    #expect(events.count == 7)
    #expect(events.contains(.object(["kind": "file_chooser", "response": "withdrawn"])))
    #expect(events.contains(.object(["kind": "popup_blocked", "url": "", "reason": "Blocked"])))
    #expect(
      events.contains(
        .object([
          "kind": "certificate_error", "url": "https://a.example/", "message": "untrusted",
          "response": "cancelled",
        ])))
  }

  @Test("a download an engine starts anyway is stopped and reported")
  func startedDownloads() async throws {
    let engine = AgentFakeEngine()
    let agent = controller(engine)
    _ = await agent.perform(request("screenshot"))
    let tab = try #require(engine.tabs.first)
    var cancels = 0
    let stoppable = BrowserDownload(
      url: try testURL("https://a.example/a"), suggestedName: "a", destination: URL(filePath: "/a"),
      engine: .chromium, totalBytes: nil, cancel: { cancels += 1 })
    agent.tab(tab, didStart: stoppable)
    #expect(cancels == 1)
    let finished = BrowserDownload(
      url: nil, suggestedName: "b", destination: URL(filePath: "/b"), engine: .chromium,
      totalBytes: nil, cancel: {})
    finished.state = .complete
    agent.tab(tab, didStart: finished)
    let result = await agent.perform(request("screenshot"))
    guard case .array(let events)? = result.data["dialogs"] else {
      Issue.record("no dialogs in \(result.data)")
      return
    }
    #expect(
      events.first
        == .object(["kind": "download", "url": "https://a.example/a", "response": "cancelled"]))
    guard case .object(let failed)? = events.last, case .string(let response)? = failed["response"]
    else {
      Issue.record("no second download event")
      return
    }
    #expect(response.hasPrefix("cancel failed"))
  }

  @Test("what comes from a tab the agent doesn't own is ignored; its popup is closed")
  func strangerTabs() async throws {
    let engine = AgentFakeEngine()
    let agent = controller(engine)
    let stranger = AgentFakeTab(profile: .ephemeral("stranger"))
    let popup = AgentFakeTab(profile: .ephemeral("stranger"))
    agent.tab(
      stranger,
      didOpen: BrowserPopup(
        tab: popup, opener: stranger, targetURL: nil, disposition: .popup, requestedSize: nil))
    #expect(popup.state.isClosed)
    agent.tab(stranger, didBlock: BrowserBlockedPopup(url: nil, reason: "Blocked"))
    let result = await agent.perform(request("screenshot"))
    #expect(result.data["dialogs"] == nil)
  }

  @Test("arguments of the wrong type are refused by name")
  func wrongTypes() async throws {
    let agent = controller(AgentFakeEngine())
    let cases = [
      AgentInvalidCase(
        action: "scroll", args: ["delta_x": "far"], message: "delta_x must be a number"),
      AgentInvalidCase(
        action: "press", args: ["key": "a", "modifiers": "Shift"],
        message: "modifiers must be an array"),
      AgentInvalidCase(
        action: "press", args: ["key": "a", "modifiers": .array([.number(1)])],
        message: "modifiers must be an array"),
      AgentInvalidCase(
        action: "wait_for_load", args: ["timeout_ms": .number(0)],
        message: "timeout_ms must be positive"),
    ]
    for invalid in cases {
      let result = await agent.perform(request(invalid.action, invalid.args))
      #expect(result.error?.contains(invalid.message) == true, "\(invalid.action)")
    }
  }
}

@Suite("Agent JSON values")
struct AgentJSONValueTests {
  @Test("every JSON type round-trips")
  func roundTrip() throws {
    let value = AgentJSONValue.object([
      "null": .null, "bool": .bool(true), "number": .number(1.5), "string": "text",
      "array": .array([.number(1), .bool(false)]), "object": .object(["inner": "value"]),
    ])
    let encoded = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(AgentJSONValue.self, from: encoded) == value)
  }

  @Test("typed reads answer only for their own type")
  func typedReads() {
    #expect(AgentJSONValue.string("a").stringValue == "a")
    #expect(AgentJSONValue.number(1).stringValue == nil)
    #expect(AgentJSONValue.number(1).numberValue == 1)
    #expect(AgentJSONValue.string("a").numberValue == nil)
  }

  @Test("a malformed or empty request event says what's wrong")
  func badEvents() {
    #expect(throws: BrowserError.self) {
      try AgentBrowserActionRequest(eventJSON: Data("{".utf8), conversationID: "c")
    }
    let empty = #"{"type":"browser.action_request","action":"","action_id":""}"#
    #expect(throws: BrowserError.self) {
      try AgentBrowserActionRequest(eventJSON: Data(empty.utf8), conversationID: "c")
    }
  }

  @Test("a result with data includes it")
  func resultWithData() throws {
    let result = AgentBrowserActionResult.success(["a": .number(1)])
    let json = String(data: try result.jsonData(), encoding: .utf8)
    #expect(json?.contains(#""data":{"a":1}"#) == true)
  }
}
