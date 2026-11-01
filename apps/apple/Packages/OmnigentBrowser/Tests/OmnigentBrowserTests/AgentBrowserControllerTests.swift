import Foundation
import Testing

@testable import OmnigentBrowser

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Arguments the controller must reject, with the error it must report.
nonisolated struct AgentInvalidCase: Sendable, CustomTestStringConvertible {
  let action: String
  let args: [String: AgentJSONValue]
  let message: String
  var testDescription: String { "\(action) \(message)" }
}

nonisolated let agentInvalidCases: [AgentInvalidCase] = [
  AgentInvalidCase(action: "frobnicate", args: [:], message: "Unknown browser action: frobnicate"),
  AgentInvalidCase(
    action: "click", args: ["ref": .number(-1)], message: "ref must be a positive integer"),
  AgentInvalidCase(
    action: "click", args: ["ref": .number(1.5)], message: "ref must be a positive integer"),
  AgentInvalidCase(action: "click", args: [:], message: "A ref or selector is required"),
  AgentInvalidCase(
    action: "click", args: ["selector": .string(String(repeating: "a", count: 4097))],
    message: "at most 4096"),
  AgentInvalidCase(
    action: "click",
    args: ["ref": .number(1), "snapshot_id": .string(String(repeating: "s", count: 129))],
    message: "at most 128"),
  AgentInvalidCase(action: "type", args: ["ref": .number(1)], message: "text is required"),
  AgentInvalidCase(
    action: "snapshot", args: ["ref": .number(1)], message: "Unsupported argument \"ref\""),
  AgentInvalidCase(action: "navigate", args: ["url": "not a url"], message: "absolute URL"),
  AgentInvalidCase(action: "press", args: ["key": "Hyper"], message: "Unknown key"),
  AgentInvalidCase(
    action: "press", args: ["key": "a", "modifiers": .array(["Fn"])], message: "Unknown modifier"),
  AgentInvalidCase(action: "scroll", args: [:], message: "delta_x or delta_y"),
]

@MainActor
@Suite("Agent browser controller")
struct AgentBrowserControllerTests {
  private func request(
    _ action: String, _ args: [String: AgentJSONValue] = [:], conversation: String = "conv_1"
  ) -> AgentBrowserActionRequest {
    AgentBrowserActionRequest(
      actionID: "baction_\(action)", action: action, args: args, conversationID: conversation)
  }

  private func controller(
    _ engine: AgentFakeEngine, policy: any BrowserURLPolicy = BrowserURLRules()
  ) -> AgentBrowserController {
    AgentBrowserController(
      provider: engine, engine: .chromium, urlPolicy: policy, actionTimeout: .seconds(2))
  }

  @Test func navigateDeniedByPolicyNeverLoads() async throws {
    let engine = AgentFakeEngine()
    let rules = BrowserURLRules(allow: ["example.com"])
    let agent = controller(engine, policy: rules)
    let result = await agent.perform(request("navigate", ["url": .string("https://evil.test/")]))
    #expect(!result.ok)
    #expect(result.error?.contains("not on the allow list") == true)
    let tab = try #require(engine.tabs.first)
    #expect(tab.loads.isEmpty)
    #expect(tab.urlPolicy?.rules == rules)
    #expect(tab.popupPolicy == .requireUserGesture)
    #expect(tab.delegate === agent)
  }

  @Test func navigateLoadsWithRulesInPlaceAndReportsTheFinalURL() async throws {
    let engine = AgentFakeEngine()
    let agent = controller(engine)
    let result = await agent.perform(request("navigate", ["url": .string("https://example.com/")]))
    #expect(result.ok, "\(result.error ?? "")")
    #expect(result.data["final_url"] == .string("https://example.com/"))
    #expect(result.data["title"] == .string("Agent page"))
    let tab = try #require(engine.tabs.first)
    #expect(tab.policyAtLoad == [BrowserURLRules()])
  }

  @Test func navigationFailureIsReported() async {
    let engine = AgentFakeEngine()
    engine.configure = { tab in
      tab.state.lastError = .navigationFailed(url: nil, code: -105, message: "name not resolved")
    }
    let agent = controller(engine)
    let result = await agent.perform(request("wait_for_load"))
    #expect(!result.ok)
    #expect(result.error?.contains("name not resolved") == true)
  }

  @Test(arguments: agentInvalidCases)
  func argumentValidation(_ invalid: AgentInvalidCase) async {
    let agent = controller(AgentFakeEngine())
    let result = await agent.perform(request(invalid.action, invalid.args))
    #expect(!result.ok)
    #expect(result.error?.contains(invalid.message) == true, "\(result.error ?? "nil")")
  }

  @Test func snapshotIsParsed() async throws {
    let engine = AgentFakeEngine()
    engine.configure = { tab in
      tab.respond = { script in
        #expect(script.contains("window.__omni_refs__ = new Map()"))
        return .string(
          #"{"snapshot_id":"snap-1","url":"https://example.com/","title":"T","tree":"- button \"Go\" [ref=1]"}"#
        )
      }
    }
    let result = await controller(engine).perform(request("snapshot"))
    #expect(result.ok)
    #expect(result.data["snapshot_id"] == .string("snap-1"))
    #expect(result.data["tree"] == .string("- button \"Go\" [ref=1]"))
    #expect(result.data["dialogs"] == nil)
  }

  @Test func clickByRefResolvesTheCenterThenClicks() async throws {
    let engine = AgentFakeEngine()
    engine.configure = { tab in
      tab.respond = { script in
        #expect(script.contains("window.__omni_refs__.has(3)"))
        #expect(script.contains("\"snap-9\""))
        return .string(
          #"{"x":40,"y":25,"width":80,"height":30,"editable":false,"tag":"button"}"#)
      }
    }
    let result = await controller(engine).perform(
      request("click", ["ref": .number(3), "snapshot_id": .string("snap-9")]))
    #expect(result.ok, "\(result.error ?? "")")
    #expect(try #require(engine.tabs.first).recorder.clicks == [CGPoint(x: 40, y: 25)])
  }

  @Test func staleRefErrorsComeBackFromThePage() async throws {
    let engine = AgentFakeEngine()
    engine.configure = { tab in
      tab.respond = { _ in
        .string(#"{"error":"ref 3 not in snapshot — call browser_snapshot again"}"#)
      }
    }
    let result = await controller(engine).perform(request("click", ["ref": .number(3)]))
    #expect(!result.ok)
    #expect(result.error?.contains("not in snapshot") == true)
    #expect(try #require(engine.tabs.first).recorder.clicks.isEmpty)
  }

  private func typingEngine(value: String) -> AgentFakeEngine {
    let engine = AgentFakeEngine()
    engine.configure = { tab in
      tab.respond = { script in
        if script.contains("scrollIntoView") {
          return .string(#"{"x":10,"y":12,"width":200,"height":20,"editable":true,"tag":"input"}"#)
        }
        if script.contains("hasValue") {
          return .string(#"{"value":"\#(value)","hasValue":true}"#)
        }
        if script.contains("focused") {
          return .string(#"{"focused":true}"#)
        }
        return .undefined
      }
    }
    return engine
  }

  @Test func typeFocusesSelectsInsertsAndVerifies() async throws {
    let engine = typingEngine(value: "hello agent")
    let result = await controller(engine).perform(
      request("type", ["selector": .string("#name"), "text": .string("hello agent")]))
    #expect(result.ok, "\(result.error ?? "")")
    let tab = try #require(engine.tabs.first)
    #expect(tab.recorder.clicks == [CGPoint(x: 10, y: 12)])
    #expect(tab.recorder.inserted == ["hello agent"])
    #expect(tab.scripts.contains { $0.contains("el.select()") })
  }

  @Test func typeFailsWhenTheTextDidNotArrive() async {
    let engine = typingEngine(value: "")
    let result = await controller(engine).perform(
      request("type", ["selector": .string("#name"), "text": .string("hello")]))
    #expect(!result.ok)
    #expect(result.error?.contains("did not reach") == true)
  }

  @Test func pressAndScrollUseAgentInput() async throws {
    let engine = AgentFakeEngine()
    engine.configure = { tab in
      tab.respond = { _ in .string(#"{"x":640,"y":400}"#) }
    }
    let agent = controller(engine)
    let pressed = await agent.perform(
      request("press", ["key": .string("Enter"), "modifiers": .array([.string("Shift")])]))
    let scrolled = await agent.perform(request("scroll", ["delta_y": .number(300)]))
    #expect(pressed.ok && scrolled.ok)
    let tab = try #require(engine.tabs.first)
    #expect(tab.recorder.presses.first?.0 == .enter)
    #expect(tab.recorder.presses.first?.1 == .shift)
    #expect(tab.recorder.scrolls.first?.point == CGPoint(x: 640, y: 400))
    #expect(tab.recorder.scrolls.first?.deltaY == 300)
  }

  @Test func screenshotIsADataURL() async throws {
    let engine = AgentFakeEngine()
    let result = await controller(engine).perform(request("screenshot"))
    #expect(result.dataURL == "data:image/png;base64,iVBORw==")
    let json = try #require(String(bytes: try result.jsonData(), encoding: .utf8))
    #expect(json == #"{"data_url":"data:image/png;base64,iVBORw==","ok":true}"#)
  }

  @Test func evaluateMapsValuesToJSON() async {
    let engine = AgentFakeEngine()
    engine.configure = { tab in
      tab.respond = { _ in .object(["n": .number(.nan), "a": .array([.bool(true), .undefined])]) }
    }
    let result = await controller(engine).perform(request("evaluate", ["expression": "x"]))
    #expect(result.data["value"] == .object(["n": .null, "a": .array([.bool(true), .null])]))
  }

  @Test func promptsAreAnsweredWithoutUIAndReported() async throws {
    let engine = AgentFakeEngine()
    var answers: [String: Bool] = [:]
    engine.configure = { tab in
      tab.respond = { _ in
        .string(#"{"x":1,"y":1,"width":5,"height":5,"editable":false,"tag":"button"}"#)
      }
      tab.recorder.onClick = { [weak tab] in
        guard let tab else { return }
        let alert = BrowserDialogPrompt(
          kind: .alert, origin: nil, message: "Hi", defaultText: ""
        ) { accepted, _ in answers["alert"] = accepted }
        let confirm = BrowserDialogPrompt(
          kind: .confirm, origin: nil, message: "Sure?", defaultText: ""
        ) { accepted, _ in answers["confirm"] = accepted }
        let permission = BrowserPermissionPrompt(origin: "https://a.test", permissions: .camera) {
          #expect($0 == .deny)
        }
        for prompt in [BrowserPrompt.dialog(alert), .dialog(confirm), .permission(permission)] {
          tab.delegate?.tab(tab, didRequest: prompt)
        }
      }
    }
    let result = await controller(engine).perform(request("click", ["selector": "button"]))
    #expect(result.ok)
    #expect(answers == ["alert": true, "confirm": false])
    guard case .array(let dialogs)? = result.data["dialogs"] else {
      Issue.record("no dialogs in \(result.data)")
      return
    }
    #expect(dialogs.count == 3)
    #expect(
      dialogs.first
        == .object([
          "kind": "dialog", "type": "alert", "message": "Hi", "response": "accepted",
        ]))
    #expect(
      dialogs.last
        == .object([
          "kind": "permission", "origin": "https://a.test", "permissions": .array(["camera"]),
          "response": "denied",
        ]))
  }

  @Test func eachConversationGetsItsOwnEphemeralProfile() async throws {
    let engine = AgentFakeEngine()
    let agent = controller(engine)
    _ = await agent.perform(request("screenshot", conversation: "conv_a"))
    _ = await agent.perform(request("screenshot", conversation: "conv_b"))
    _ = await agent.perform(request("screenshot", conversation: "conv_a"))
    #expect(engine.tabs.map(\.profile) == [.ephemeral("agent:conv_a"), .ephemeral("agent:conv_b")])
    agent.close(conversationID: "conv_a")
    #expect(engine.tabs[0].state.isClosed)
    #expect(!engine.tabs[1].state.isClosed)
  }

  @Test func popupsBecomeTheActivePage() async throws {
    let engine = AgentFakeEngine()
    let agent = controller(engine)
    _ = await agent.perform(request("screenshot"))
    let opener = try #require(engine.tabs.first)
    let popup = AgentFakeTab(profile: opener.profile)
    agent.tab(
      opener,
      didOpen: BrowserPopup(
        tab: popup, opener: opener, targetURL: URL(string: "https://example.com/p"),
        disposition: .popup, requestedSize: nil))
    #expect(agent.activeTab(conversationID: "conv_1") === popup)
    #expect(popup.delegate === agent)
    popup.close()
    #expect(agent.activeTab(conversationID: "conv_1") === opener)
  }
}

@Suite("Agent action wire format")
struct AgentActionWireTests {
  @Test func failureJSONOmitsAbsentKeys() throws {
    let data = try AgentBrowserActionResult.failure("boom").jsonData()
    #expect(String(bytes: data, encoding: .utf8) == #"{"error":"boom","ok":false}"#)
  }

  @Test func requestDecodesTheRawEvent() throws {
    let json = Data(
      #"{"type":"browser.action_request","action_id":"baction_1","action":"type","args":{"ref":2,"text":"hi"}}"#
        .utf8)
    let request = try AgentBrowserActionRequest(eventJSON: json, conversationID: "conv_9")
    #expect(request.actionID == "baction_1")
    #expect(request.args == ["ref": .number(2), "text": .string("hi")])
    let nullArgs = try AgentBrowserActionRequest(
      eventJSON: Data(#"{"action_id":"b","action":"snapshot","args":null}"#.utf8),
      conversationID: "c")
    #expect(nullArgs.args.isEmpty)
    #expect(throws: BrowserError.self) {
      try AgentBrowserActionRequest(
        eventJSON: Data(#"{"type":"ui.open_file","action_id":"b","action":"x"}"#.utf8),
        conversationID: "c")
    }
  }
}
