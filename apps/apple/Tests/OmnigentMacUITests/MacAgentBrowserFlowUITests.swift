import Foundation
import XCTest

/// A session's agent drives the app's own Chromium over Chrome DevTools while the window is in
/// the background and another session's tabs are shown: the real `chrome-devtools-mcp`, through
/// the runner's scoped proxy, the owner-only relay and the app's gated endpoint
/// (`Tools/agent-browser-driver.py`). Then the page's agent strip, Take Over refusing the agent,
/// Hand Back, and the tab staying once the agent lets go. The tab's accessibility label carries
/// its badge.
///
/// Needs a server with `agent_browser_devtools` on and the pinned chrome-devtools-mcp installed
/// in `TEST_RUNNER_OMNIGENT_AGENT_BROWSER_DATA` (the agent browser VM job prepares both).
final class MacAgentBrowserFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  @MainActor
  func testAnAgentDrivesTheMacBrowserInTheBackground() async throws {
    let live = MacLiveUITestSupport(self)
    guard let data = MacLiveUITestSupport.environment["OMNIGENT_AGENT_BROWSER_DATA"], !data.isEmpty
    else { throw XCTSkip("Run by the agent browser job, which installs chrome-devtools-mcp.") }
    let info = try await live.serverJSON("GET", "/v1/info")
    let features = info["features"] as? [String: Any] ?? [:]
    try XCTSkipUnless(
      features["agent_browser_devtools"] as? Bool == true,
      "the server does not offer agent_browser_devtools")
    let agentSession = try live.fixtureSession()
    let otherSession = try live.longSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(agentSession, in: app)
    live.open(otherSession, in: app)
    // The window goes to the background, showing another session's tabs.
    XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
    // No process of the app listens for DevTools before an agent asks.
    XCTAssertEqual(try Self.appListeners(), [], "a listener before any agent asked")

    let driver = try AgentBrowserDriver(server: live.server, session: agentSession, data: data)
    defer { driver.stop() }
    try actInTheBackground(driver, app: app)

    app.activate()
    live.open(agentSession, in: app)
    // The page retitles itself when the agent clicks Greet; VoiceOver hears the agent with it.
    let agentTab = live.tabs("browser", in: app).matching(
      NSPredicate(format: "label == %@", "Greeted Ada, Agent is controlling this tab")
    ).firstMatch
    XCTAssertTrue(agentTab.appears(within: 20), "no agent tab\n\(app.debugDescription)")
    live.click(agentTab, "the agent's tab")
    XCTAssertTrue(
      live.element("browser.agent.control", in: app).appears(within: 10),
      "no agent strip on the page\n\(driver.logTail)")
    try await takeOverAndHandBack(driver, live: live, app: app)

    // The agent lets go: the badge and strip leave, the tab stays.
    driver.quit()
    XCTAssertTrue(
      live.element("browser.agent.control", in: app).disappears(within: 30), "the strip stayed")
    let releasedTab = live.tabs("browser", in: app).matching(
      NSPredicate(format: "label == %@", "Greeted Ada")
    ).firstMatch
    XCTAssertTrue(releasedTab.appears(within: 10), "the agent's tab closed or kept its badge")
  }

  /// The agent fills and clicks a page in a new tab, reads it and takes a screenshot, while the
  /// app stays in the background and Chromium opens no port.
  @MainActor
  private func actInTheBackground(_ driver: AgentBrowserDriver, app: XCUIApplication) throws {
    let ready = try driver.answer(timeout: 300)
    XCTAssertEqual(ready["ok"] as? Bool, true, "\(ready)")
    let acted = try driver.send("act", timeout: 180)
    XCTAssertEqual(acted["ok"] as? Bool, true, "\(acted)")
    // Fill and click reached the page, which stayed visible and focused for the agent.
    let greeting = acted["greeting"] as? String ?? ""
    XCTAssertTrue(greeting.contains("Hello Ada|visible|true"), greeting)
    XCTAssertGreaterThan(acted["screenshot_base64_chars"] as? Int ?? 0, 1_000, "\(acted)")
    XCTAssertNotEqual(app.state, .runningForeground, "the app took the focus")
    // Chromium opened no port while serving the agent. (The gate is a Network framework
    // listener, which lsof does not list; the agent reaching the page proves it listens.)
    let listeners = try Self.appListeners()
    XCTAssertTrue(
      listeners.allSatisfy {
        $0.hasPrefix("Omnigent 127.0.0.1:") || $0.hasPrefix("Omnigent [::1]:")
      }, "\(listeners)")
  }

  /// Take Over refuses the agent's input; Hand Back gives it back.
  @MainActor
  private func takeOverAndHandBack(
    _ driver: AgentBrowserDriver, live: MacLiveUITestSupport, app: XCUIApplication
  ) async throws {
    live.click(live.element("browser.agent.takeOver", in: app), "Take Over")
    let handBack = live.element("browser.agent.handBack", in: app)
    XCTAssertTrue(handBack.appears(within: 10), "no Hand Back")
    // The proxy trusts an owner it read in the last second.
    try await Task.sleep(for: .seconds(2))
    // The proxy refuses the click's input events. chrome-devtools-mcp retries them until its
    // timeout and words the failure itself; the user_in_control text does not reach the agent.
    let refused = try driver.send("click", timeout: 90)
    XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
    live.click(handBack, "Hand Back")
    XCTAssertTrue(live.element("browser.agent.takeOver", in: app).appears(within: 10))
    try await Task.sleep(for: .seconds(2))
    let clicked = try driver.send("click", timeout: 60)
    XCTAssertEqual(clicked["ok"] as? Bool, true, "\(clicked)")
  }

  /// TCP listeners of the app's processes (the app, its Web Host and helpers), as
  /// "<command> <address>" lines.
  private static func appListeners() throws -> [String] {
    let lsof = Process()
    lsof.executableURL = URL(filePath: "/usr/sbin/lsof")
    lsof.arguments = ["+c", "0", "-nP", "-a", "-c", "Omnigent", "-iTCP", "-sTCP:LISTEN"]
    let output = Pipe()
    lsof.standardOutput = output
    try lsof.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    lsof.waitUntilExit()
    let text = String(bytes: data, encoding: .utf8) ?? ""
    return text.split(separator: "\n").dropFirst().compactMap { line in
      let fields = line.split(separator: " ", omittingEmptySubsequences: true)
      // The UI test runner is an Omnigent* process too, but not the app's.
      guard let command = fields.first, !command.contains("Runner"), fields.count >= 9 else {
        return nil
      }
      let name = command.replacingOccurrences(of: "\\x20", with: " ")
      return "\(name) \(fields[8])"
    }
  }
}

/// `Tools/agent-browser-driver.py`, one command per line in, one JSON answer per line out.
@MainActor
final class AgentBrowserDriver {
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let lines = LineBuffer()
  private let log = FileManager.default.temporaryDirectory.appending(
    path: "agent-browser-driver-\(UUID().uuidString).log")

  /// The end of the driver's log.
  var logTail: String {
    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? "(no driver log)"
    return String(text.suffix(4_000))
  }

  /// Starts the driver for `session` on `server`, with chrome-devtools-mcp installed in `data`.
  init(server: String, session: String, data: String) throws {
    // apps/apple/Tests/OmnigentMacUITests/<file> -> the checkout.
    let repo = (0..<5).reduce(URL(filePath: #filePath)) { url, _ in
      url.deletingLastPathComponent()
    }
    let work = FileManager.default.temporaryDirectory.appending(
      path: "agent-browser-\(UUID().uuidString)")
    process.executableURL = repo.appending(path: ".venv/bin/python")
    process.arguments = [
      repo.appending(path: "apps/apple/Tools/agent-browser-driver.py").path, "--server", server,
      "--session", session, "--data-dir", data, "--work-dir", work.path,
    ]
    process.currentDirectoryURL = repo
    var environment = ProcessInfo.processInfo.environment
    environment["PYTHONPATH"] = [
      repo.path, "\(repo.path)/sdks/python-client", "\(repo.path)/sdks/ui",
    ]
    .joined(separator: ":")
    environment["PATH"] = "\(environment["PATH"] ?? "/usr/bin:/bin"):/opt/homebrew/bin"
    process.environment = environment
    process.standardInput = input
    process.standardOutput = output
    // The driver's and the proxy's log, quoted when an agent step fails.
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: log.path, contents: nil)
    process.standardError = try FileHandle(forWritingTo: log)
    let lines = lines
    output.fileHandleForReading.readabilityHandler = { handle in lines.append(handle.availableData)
    }
    try process.run()
  }

  /// The next answer.
  func answer(timeout: TimeInterval) throws -> [String: Any] {
    guard let line = lines.next(timeout: timeout) else {
      throw DriverError.noAnswer(running: process.isRunning)
    }
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
    return try XCTUnwrap(object as? [String: Any], line)
  }

  /// Sends `command` and returns its answer.
  func send(_ command: String, timeout: TimeInterval) throws -> [String: Any] {
    try input.fileHandleForWriting.write(contentsOf: Data("\(command)\n".utf8))
    return try answer(timeout: timeout)
  }

  /// Disconnects the agent and waits for the driver to exit.
  func quit() {
    do {
      try input.fileHandleForWriting.write(contentsOf: Data("quit\n".utf8))
    } catch {
      XCTFail("the driver did not take quit: \(error)")
    }
    let deadline = Date().addingTimeInterval(30)
    while process.isRunning, Date() < deadline { usleep(100_000) }
    XCTAssertFalse(process.isRunning, "the driver did not exit")
  }

  /// Ends the driver if it still runs.
  func stop() {
    output.fileHandleForReading.readabilityHandler = nil
    if process.isRunning { process.terminate() }
  }

  enum DriverError: Error {
    case noAnswer(running: Bool)
  }
}

/// Complete lines of the driver's output, as they arrive on its pipe's queue.
final class LineBuffer: @unchecked Sendable {
  private let lock = NSCondition()
  private var pending = Data()
  private var lines: [String] = []

  func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    pending.append(data)
    while let newline = pending.firstIndex(of: 0x0A) {
      lines.append(String(bytes: pending[pending.startIndex..<newline], encoding: .utf8) ?? "")
      pending = Data(pending[(newline + 1)...])
    }
    lock.broadcast()
  }

  func next(timeout: TimeInterval) -> String? {
    lock.lock()
    defer { lock.unlock() }
    let deadline = Date().addingTimeInterval(timeout)
    while lines.isEmpty {
      guard lock.wait(until: deadline) else { return nil }
    }
    return lines.removeFirst()
  }
}
