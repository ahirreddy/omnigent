import XCTest

/// Opt-in real generation. The Python observer can watch the same turn in the normal web UI.
@MainActor
final class NativeProgressiveStreamingUITests: XCTestCase {
  private var app: XCUIApplication!
  private var evidence: URL?
  private var report: [String: Any] = [:]
  private var samples: [[String: Any]] = []
  private let transport = progressiveTransport()

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--reset-demo", "--live-page-size", "100"]
  }

  override func tearDownWithError() throws {
    report["samples"] = samples
    report["finished_epoch"] = Date().timeIntervalSince1970
    if JSONSerialization.isValidJSONObject(report),
      let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    {
      let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
      attachment.name = "native-progressive-evidence.json"
      attachment.lifetime = .keepAlways
      add(attachment)
      if let evidence { try data.write(to: evidence.appendingPathComponent("native-result.json")) }
    }
    app.terminate()
    transport.invalidateAndCancel()
  }

  func testOptInRealModelTextVisiblyGrowsBeforeCompletion() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["OMNI_PROGRESSIVE_UI_TESTS"] == "1" else {
      throw XCTSkip("Set TEST_RUNNER_OMNI_PROGRESSIVE_UI_TESTS=1 for real progressive UI proof.")
    }
    let sessionID = try XCTUnwrap(environment["OMNI_PROGRESSIVE_SESSION_ID"])
    let probeID = try XCTUnwrap(environment["OMNI_PROGRESSIVE_PROBE_ID"])
    XCTAssertTrue(sessionID.allSatisfy { $0.isLetter || $0.isNumber })
    XCTAssertTrue(probeID.allSatisfy { $0.isLetter || $0.isNumber })
    if let path = environment["OMNI_PROGRESSIVE_EVIDENCE_DIR"] {
      evidence = URL(fileURLWithPath: path, isDirectory: true)
      try FileManager.default.createDirectory(at: evidence!, withIntermediateDirectories: true)
    }
    let begin = "NATIVE_STREAM_BEGIN_\(probeID)"
    let end = "NATIVE_STREAM_END_\(probeID)"
    let prompt =
      "Begin your reply with \(begin) on its own line. "
      + "Then write 60 plain prose sentences, each at least 20 words long, about a peaceful "
      + "imaginary garden through the seasons (about 8000 characters total). "
      + "End with \(end) on its own line. No markdown, numbering, preface or afterword. "
      + "Answer directly in chat. Do not call tools, run commands, or access files."
    report = ["probe_id": probeID, "session_id": sessionID, "live_model": true, "passed": false]
    let session = try await requireDedicatedSession(sessionID)
    report["model_override"] = session["model_override"] ?? NSNull()
    report["harness"] = session["harness"] ?? NSNull()
    if let evidence {
      // A coordinated run must be listening in web and SSE before native sends once.
      let ready = try Data(contentsOf: evidence.appendingPathComponent("ready.json"))
      let plan = try XCTUnwrap(JSONSerialization.jsonObject(with: ready) as? [String: Any])
      XCTAssertEqual(plan["session_id"] as? String, sessionID)
      XCTAssertEqual(plan["probe_id"] as? String, probeID)
      XCTAssertEqual(plan["prompt"] as? String, prompt)
    }

    app.launch()
    try tap("connect-local")
    XCTAssertTrue(element("live-workspace-notice").waitForExistence(timeout: 20))
    let row = app.buttons["session-row-\(sessionID)"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 15), "Prepare a fresh disposable session first.")
    row.tap()
    let connected = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "Connected"),
      object: element("conversation-connection-status"))
    XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 20), .completed)

    let wire = ProgressiveWireObserver(begin: begin)
    let watch = Task { await wire.listen(sessionID: sessionID) }
    defer { watch.cancel() }
    let readyDeadline = Date().addingTimeInterval(20)
    while !(await wire.state()).ready && Date() < readyDeadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    let readyState = await wire.state()
    XCTAssertTrue(readyState.ready, readyState.failure ?? "SSE readiness heartbeat absent.")
    try tap("expand-composer")
    let editor = element("expanded-composer-input")
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.tap()
    editor.typeText(prompt)
    report["send_started_epoch"] = Date().timeIntervalSince1970
    try tap("expanded-send-message")

    let deadline = Date().addingTimeInterval(240)
    var previous = ""
    var finalState = await wire.state()
    while Date() < deadline {
      finalState = await wire.state()
      report["wire"] = finalState.json
      if let failure = finalState.failure { throw error(failure) }
      let reply = app.staticTexts.matching(
        NSPredicate(
          format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "message-text-", begin)
      ).firstMatch
      if reply.exists {
        let observed = Date().timeIntervalSince1970
        let text = reply.label
        if text != previous {
          previous = text
          let visible = reply.isHittable
          let identifier = reply.identifier
          let index = samples.count
          let started = Date().timeIntervalSince1970
          let screenshot = XCUIScreen.main.screenshot()
          let finished = Date().timeIntervalSince1970
          let name = "native-\(index).png"
          let attachment = XCTAttachment(screenshot: screenshot)
          attachment.name = name
          attachment.lifetime = .keepAlways
          add(attachment)
          if let evidence {
            try screenshot.pngRepresentation.write(to: evidence.appendingPathComponent(name))
          }
          samples.append([
            "text": text, "epoch": observed, "visible": visible, "identifier": identifier,
            "capture_started_epoch": started, "capture_finished_epoch": finished,
            "screenshot": name,
          ])
        }
      }
      if finalState.completedEpoch != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    finalState = await wire.state()
    report["wire"] = finalState.json
    let completed = try XCTUnwrap(
      finalState.completedEpoch, "No completed real reply within 240 seconds.")
    let finalText = try XCTUnwrap(finalState.finalText)
    let finalID = try XCTUnwrap(finalState.finalID)
    let boundedText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertTrue(boundedText.hasPrefix(begin) && boundedText.hasSuffix(end))

    // Check the committed final view before asserting growth so failed/bulk runs retain screenshots.
    let committed = element("message-text-\(finalID)")
    XCTAssertTrue(committed.waitForExistence(timeout: 20))
    XCTAssertEqual(normalized(committed.label), normalized(finalText))
    capture("native-final.png")
    let items = try await get("/v1/sessions/\(sessionID)/items?limit=1000&order=desc")
    let stored = try XCTUnwrap(items["data"] as? [[String: Any]])
    XCTAssertEqual(
      stored.filter { $0["role"] as? String == "user" && progressiveItemText($0) == prompt }.count,
      1)
    XCTAssertEqual(
      stored.filter { $0["role"] as? String == "assistant" && progressiveItemText($0) == finalText }
        .count, 1)
    let actual = try await get("/v1/sessions/\(sessionID)?include_items=false")
    report["actual_model"] = actual["llm_model"] ?? NSNull()
    if let expected = session["model_override"] as? String {
      XCTAssertEqual(
        actual["llm_model"] as? String, expected, "Verify the runner actually used the override.")
    }

    let groups = Dictionary(grouping: finalState.chunks, by: \.identity)
    let matching = groups.values.filter { $0.map(\.text).joined().contains(begin) }
    XCTAssertEqual(matching.count, 1, "Deltas must belong to one generated message.")
    let chunks = try XCTUnwrap(matching.first)
    XCTAssertEqual(
      chunks.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines), boundedText)
    XCTAssertGreaterThanOrEqual(
      chunks.count, 2, "One full-text delta is not progressive streaming.")
    XCTAssertGreaterThanOrEqual(chunks.last!.epoch - chunks.first!.epoch, 0.25)
    XCTAssertLessThan(chunks.first!.text.count, finalText.count)
    XCTAssertTrue(chunks.allSatisfy { $0.epoch < completed })

    let eligible = samples.filter { sample in
      guard let text = sample["text"] as? String,
        let finished = sample["capture_finished_epoch"] as? Double,
        let identifier = sample["identifier"] as? String
      else { return false }
      return sample["visible"] as? Bool == true && finished < completed
        && identifier.hasPrefix("message-text-live:") && !text.isEmpty
        && normalized(finalText).hasPrefix(normalized(text))
        && normalized(text).count < normalized(finalText).count
    }
    let grew = eligible.contains { first in
      eligible.contains { later in
        let a = normalized(first["text"] as! String)
        let b = normalized(later["text"] as! String)
        return (later["epoch"] as! Double) - (first["epoch"] as! Double) >= 0.25
          && b.count > a.count && b.hasPrefix(a)
      }
    }
    XCTAssertTrue(
      grew,
      "Need two visible, screenshot-backed strict prefixes before completion; bulk output must fail."
    )
    report["passed"] = true
  }

  private func requireDedicatedSession(_ id: String) async throws -> [String: Any] {
    let info = try await get("/v1/info")
    let me = try await get("/v1/me")
    XCTAssertEqual(info["single_user"] as? Bool, true)
    XCTAssertEqual(info["accounts_enabled"] as? Bool, false)
    XCTAssertEqual(me["user_id"] as? String, "local")
    var repo = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repo.deleteLastPathComponent() }
    let session = try await get("/v1/sessions/\(id)?include_items=false")
    XCTAssertTrue((session["title"] as? String ?? "").hasPrefix("Native streaming validation "))
    XCTAssertEqual(
      session["workspace"] as? String,
      repo.appendingPathComponent(".native-lab-server/chat-workspace").path)
    XCTAssertEqual(session["host_online"] as? Bool, true)
    XCTAssertTrue(["idle", "failed"].contains(session["status"] as? String ?? ""))
    return session
  }

  private func get(_ path: String) async throws -> [String: Any] {
    let url = URL(string: "http://127.0.0.1:6767" + path)!
    let (data, response) = try await transport.data(from: url)
    guard let http = response as? HTTPURLResponse, http.url == url, http.statusCode == 200 else {
      throw error("Loopback request failed; response body omitted.")
    }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func element(_ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func tap(_ id: String) throws {
    let button = app.buttons[id].firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 10))
    XCTAssertTrue(button.isEnabled && button.isHittable, "Unavailable action: \(id)")
    button.tap()
  }

  private func capture(_ name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    if let evidence {
      try? screenshot.pngRepresentation.write(to: evidence.appendingPathComponent(name))
    }
  }

  private func normalized(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private func error(_ message: String) -> NSError {
    NSError(
      domain: "NativeProgressiveStreaming", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

private struct ProgressiveChunk: Sendable {
  let identity: String
  let text: String
  let epoch: Double
}

private struct ProgressiveWireState: Sendable {
  var ready = false
  var chunks: [ProgressiveChunk] = []
  var finalText: String?
  var finalID: String?
  var completedEpoch: Double?
  var failure: String?
  var wrapperCompletions: [Double] = []

  var json: [String: Any] {
    [
      "ready": ready,
      "chunks": chunks.map { ["identity": $0.identity, "text": $0.text, "epoch": $0.epoch] },
      "completed_epoch": completedEpoch as Any? ?? NSNull(),
      "final_text": finalText as Any? ?? NSNull(),
      "final_id": finalID as Any? ?? NSNull(), "failure": failure as Any? ?? NSNull(),
      "wrapper_completions": wrapperCompletions,
    ]
  }
}

private actor ProgressiveWireObserver {
  private let begin: String
  private var value = ProgressiveWireState()
  private var indices: [String: Int] = [:]

  init(begin: String) { self.begin = begin }
  func state() -> ProgressiveWireState { value }

  func listen(sessionID: String) async {
    let transport = progressiveTransport()
    defer { transport.invalidateAndCancel() }
    do {
      let url = URL(string: "http://127.0.0.1:6767/v1/sessions/\(sessionID)/stream")!
      let (bytes, response) = try await transport.bytes(from: url)
      guard let http = response as? HTTPURLResponse, http.url == url, http.statusCode == 200 else {
        value.failure = "SSE did not return HTTP 200 from the local session."
        return
      }
      for try await line in bytes.lines {
        try Task.checkCancellation()
        guard line.hasPrefix("data: "), line != "data: [DONE]",
          let data = String(line.dropFirst(6)).data(using: .utf8),
          let event = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }
        let epoch = Date().timeIntervalSince1970
        let kind = event["type"] as? String
        if kind == "session.heartbeat" { value.ready = true }
        if kind == "response.completed" { value.wrapperCompletions.append(epoch) }
        if kind == "response.failed"
          || (kind == "session.status" && event["status"] as? String == "failed")
        {
          value.failure = "Runner reported failure; provider payload omitted."
          return
        }
        if kind == "response.output_text.delta", let delta = event["delta"] as? String,
          !delta.isEmpty
        {
          let identity =
            event["message_id"] as? String ?? event["item_id"] as? String
            ?? event["response_id"] as? String ?? "unidentified"
          if let index = event["index"] as? Int {
            if index <= indices[identity, default: -1] { continue }
            indices[identity] = index
          }
          value.chunks.append(ProgressiveChunk(identity: identity, text: delta, epoch: epoch))
        }
        if kind == "response.output_item.done", let item = event["item"] as? [String: Any],
          item["role"] as? String == "assistant", progressiveItemText(item).contains(begin)
        {
          value.finalText = progressiveItemText(item)
          value.finalID = item["id"] as? String
          value.completedEpoch = epoch
          return
        }
      }
      value.failure = "SSE ended before the marked assistant item completed."
    } catch is CancellationError {
      return
    } catch {
      value.failure = "SSE transport failed (details omitted)."
    }
  }
}

private func progressiveItemText(_ item: [String: Any]) -> String {
  if let text = item["content"] as? String { return text }
  return (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
}

private func progressiveTransport() -> URLSession {
  let config = URLSessionConfiguration.ephemeral
  config.httpCookieStorage = nil
  config.httpShouldSetCookies = false
  config.urlCredentialStorage = nil
  config.timeoutIntervalForRequest = 300
  return URLSession(
    configuration: config, delegate: ProgressiveTransportDelegate(), delegateQueue: nil)
}

private final class ProgressiveTransportDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    completionHandler(.cancelAuthenticationChallenge, nil)
  }
}
