import Foundation
import Testing

@testable import OmnigentBrowser

/// The real controller on the real system engine: navigate, type, click, snapshot.
@MainActor
@Suite("Agent browser on WebKit", .serialized)
struct AgentBrowserWebKitTests {
  @Test func navigateTypeClickAndSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "AgentBrowserTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let page = directory.appending(path: "form.html")
    try """
    <!doctype html><title>Agent form</title><body>
    <input id=name placeholder="Your name">
    <button id=go onclick="window.clicks = (window.clicks || 0) + 1">Go</button>
    </body>
    """.write(to: page, atomically: true, encoding: .utf8)
    let agent = AgentBrowserController(
      provider: DefaultBrowserEngineProvider(), engine: .system,
      urlPolicy: BrowserURLRules.unrestricted)
    defer { agent.closeAll() }
    func run(_ action: String, _ args: [String: AgentJSONValue] = [:]) async
      -> AgentBrowserActionResult
    {
      await agent.perform(
        AgentBrowserActionRequest(
          actionID: "baction_\(action)", action: action, args: args, conversationID: "webkit"))
    }
    let navigated = await run("navigate", ["url": .string(page.absoluteString)])
    #expect(navigated.ok, "\(navigated.error ?? "")")
    #expect(navigated.data["title"] == "Agent form")
    let typed = await run("type", ["selector": "#name", "text": "hello webkit"])
    #expect(typed.ok, "\(typed.error ?? "")")
    let clicked = await run("click", ["selector": "#go"])
    #expect(clicked.ok, "\(clicked.error ?? "")")
    let clicks = await run("evaluate", ["expression": "window.clicks"])
    #expect(clicks.data["value"] == .number(1))
    let snapshot = await run("snapshot")
    #expect(snapshot.ok, "\(snapshot.error ?? "")")
    let tree = snapshot.data["tree"]?.stringValue ?? ""
    #expect(tree.contains("- textbox \"Your name\" [ref=1]"), "\(tree)")
    #expect(tree.contains("- button \"Go\" [ref=2]"), "\(tree)")
    let value = await run("evaluate", ["expression": "document.querySelector('#name').value"])
    #expect(value.data["value"] == "hello webkit")
    let retyped = await run(
      "type",
      [
        "ref": .number(1), "snapshot_id": snapshot.data["snapshot_id"] ?? .null,
        "text": "replaced",
      ])
    #expect(retyped.ok, "\(retyped.error ?? "")")
    let stale = await run("click", ["ref": .number(1), "snapshot_id": "old"])
    #expect(stale.error?.contains("was superseded") == true, "\(stale.error ?? "")")
    let shot = await run("screenshot")
    #expect(shot.dataURL?.hasPrefix("data:image/png;base64,") == true, "\(shot.error ?? "")")
  }
}
