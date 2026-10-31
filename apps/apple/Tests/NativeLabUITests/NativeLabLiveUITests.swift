import XCTest

@MainActor
final class NativeLabLiveUITests: XCTestCase {
  private var app: XCUIApplication!
  private let fixtureID = "f1000000000000000000000000000001"
  private let streamFixtureID = "f2000000000000000000000000000001"
  private var verifiedStreamFixture = false
  private let transport: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 10
    return URLSession(
      configuration: configuration, delegate: FixtureTransportDelegate(), delegateQueue: nil)
  }()

  override func setUpWithError() throws {
    continueAfterFailure = false
    verifiedStreamFixture = false
    app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--reset-demo", "--live-page-size", "2"]
  }

  override func tearDownWithError() throws {
    app.terminate()
    app = nil
  }

  func testLiveResourceHistoryHasNativeDetailsWithoutChangingServerData() async throws {
    try await requireLocalFixture()
    let sessionID = "7b829c941f034a758f9812102638e85c"
    let session = try await requestJSON(
      path: "/v1/sessions/\(sessionID)",
      query: [URLQueryItem(name: "include_items", value: "false")])
    guard session["title"] as? String == "Native configuration validation" else {
      throw XCTSkip("The isolated configuration fixture is unavailable.")
    }
    let before = try await storedItems(sessionID: sessionID)
    let resource = try XCTUnwrap(before.first { $0["type"] as? String == "resource_event" })
    let itemID = try XCTUnwrap(resource["id"] as? String)
    let resourceID = try XCTUnwrap(resource["resource_id"] as? String)
    app.launch()
    tap("connect-local")
    XCTAssertTrue(element("live-workspace-notice").waitForExistence(timeout: 15))
    openLiveSession(sessionID)
    waitForConnectedStream()
    XCTAssertFalse(app.buttons["activity-toggle-\(itemID)"].exists)
    capture("hierarchy-live-conversation")
    tap("session-options")
    tap("session-activity")
    XCTAssertTrue(app.buttons["activity-toggle-state-status"].waitForExistence(timeout: 5))
    tap("lifecycle-history")
    tap("activity-toggle-\(itemID)")
    XCTAssertEqual(element("activity-detail-\(itemID)-id").label, resourceID)
    XCTAssertTrue(element("activity-detail-\(itemID)-event").label.contains("session.resource."))
    XCTAssertFalse(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "preview not supported"))
        .firstMatch.exists)
    capture("hierarchy-live-resource-details")
    tap("session-activity-done")
    XCTAssertTrue(app.buttons["composer-configuration"].exists)
    let after = try await storedItems(sessionID: sessionID)
    XCTAssertEqual(
      try JSONSerialization.data(withJSONObject: before, options: .sortedKeys),
      try JSONSerialization.data(withJSONObject: after, options: .sortedKeys))
  }

  func testLocalConnectionKeepsInboxAndComposerWhileReadingPages() async throws {
    try await requireLocalFixture()
    app.launch()
    tap("connect-local")
    XCTAssertTrue(element("live-workspace-notice").waitForExistence(timeout: 15))
    assertAllTabs()
    XCTAssertTrue(app.buttons["new-session"].exists)
    XCTAssertTrue(app.buttons["new-session"].isEnabled)
    XCTAssertFalse(app.buttons["refresh-sessions"].exists)
    XCTAssertFalse(app.buttons["session-row-demo-design"].exists)
    openLiveSession("a1000000000000000000000000000001")
    XCTAssertTrue(
      element("conversation-a1000000000000000000000000000001").waitForExistence(timeout: 10))
    goBack()
    openLiveSession(fixtureID)
    XCTAssertTrue(message(60).waitForExistence(timeout: 10))
    let visibleMessage = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true"), object: message(60))
    XCTAssertEqual(XCTWaiter.wait(for: [visibleMessage], timeout: 10), .completed)
    XCTAssertTrue(element("composer-input").exists)
    XCTAssertTrue(element("composer-input").isEnabled)
    XCTAssertTrue(app.buttons["send-message"].exists)
    XCTAssertFalse(app.buttons["send-message"].isEnabled)
    XCTAssertFalse(app.buttons["refresh-conversation"].exists)
    capture("live-local-conversation")
    let history = app.scrollViews["conversation-\(fixtureID)"]
    reveal(app.buttons["load-older-messages"], in: history)
    tap("load-older-messages")
    reveal(message(1), in: history)
    XCTAssertTrue(message(1).exists)
    XCTAssertFalse(app.buttons["load-older-messages"].exists)
    XCTAssertEqual(
      app.staticTexts.matching(NSPredicate(format: "label == %@", "Local API fixture message 01."))
        .count,
      1)
    capture("live-older-history")
  }

  func testServerDeltasAppearWithoutRefreshAndCommitOnlyOnce() async throws {
    _ = try await requireStreamFixture()
    app.launch()
    tap("connect-local")
    XCTAssertTrue(element("live-workspace-notice").waitForExistence(timeout: 15))
    assertAllTabs()
    openLiveSession(streamFixtureID)
    waitForConnectedStream()

    let token = UUID().uuidString
    let prefix = "Live UI stream \(token)"
    let suffix = " arrived without refresh."
    let complete = prefix + suffix
    let messageID = "ui-\(token)"
    // The enqueue turn can end before the harness emits any assistant text.
    _ = try await postFixtureEvent(
      "external_session_status", data: ["status": "running", "response_id": "enqueue-\(token)"])
    _ = try await postFixtureEvent(
      "external_session_status", data: ["status": "idle", "response_id": "enqueue-\(token)"])
    _ = try await postFixtureEvent(
      "external_output_text_delta",
      data: [
        "delta": prefix, "message_id": messageID, "index": 0, "final": false,
      ])
    XCTAssertTrue(text(prefix).waitForExistence(timeout: 15))
    XCTAssertTrue(text(prefix).isHittable)
    XCTAssertFalse(text(complete).exists)
    capture("live-stream-prefix-after-enqueue-completion")
    _ = try await postFixtureEvent(
      "external_output_text_delta",
      data: [
        "delta": suffix, "message_id": messageID, "index": 1, "final": true,
      ])
    XCTAssertTrue(text(complete).waitForExistence(timeout: 15))
    XCTAssertTrue(text(complete).isHittable)
    capture("live-stream-grown-before-commit")
    let acknowledgement = try await postFixtureEvent(
      "external_conversation_item",
      data: [
        "item_type": "message", "response_id": "ui-response-\(token)",
        "item_data": [
          "role": "assistant", "agent": "Native UI fixture",
          "content": [["type": "output_text", "text": complete]],
        ],
      ])
    let committedID = try XCTUnwrap(acknowledgement["item_id"] as? String)
    XCTAssertTrue(element("message-text-\(committedID)").waitForExistence(timeout: 15))
    XCTAssertEqual(
      textMatches(complete).count, 1, "The committed item must replace its live preview.")
    let items = try await storedItems(sessionID: streamFixtureID)
    XCTAssertEqual(
      items.filter { $0["role"] as? String == "assistant" && itemText($0) == complete }.count, 1)
    capture("live-stream-final-deduplicated")
  }

  func testLiveInboxReceivesAndResolvesHarmlessFixtureApproval() async throws {
    let fixture = try await requireStreamFixture()
    guard (fixture["pending_elicitations"] as? [[String: Any]] ?? []).isEmpty else {
      throw failure(
        "The isolated stream fixture has an unresolved request from an earlier run. Resolve it before retrying."
      )
    }
    app.launch()
    tap("connect-local")
    XCTAssertTrue(element("live-workspace-notice").waitForExistence(timeout: 15))
    assertAllTabs()
    app.tabBars.buttons["Inbox"].tap()
    let prompt =
      "UI validation \(UUID().uuidString): acknowledge this harmless test. No command will run."
    let acknowledgement = try await postFixtureEvent("mcp_elicitation", data: ["message": prompt])
    let decisionID = try XCTUnwrap(acknowledgement["elicitation_id"] as? String)
    XCTAssertTrue(app.buttons["session-row-\(streamFixtureID)"].waitForExistence(timeout: 30))
    tap("session-row-\(streamFixtureID)")
    let approve = app.buttons["approval-approve-\(decisionID)"]
    XCTAssertTrue(approve.waitForExistence(timeout: 15))
    let history = app.scrollViews["conversation-\(streamFixtureID)"]
    for _ in 0..<8 {
      if approve.isHittable { break }
      history.swipeUp()
    }
    tap("approval-approve-\(decisionID)")
    waitUntilGone(approve)
    let resolved = try await requestJSON(
      path: "/v1/sessions/\(streamFixtureID)/elicitations/\(decisionID)")
    XCTAssertEqual(resolved["status"] as? String, "resolved")
    goBack()
    waitUntilGone(app.buttons["session-row-\(streamFixtureID)"])
    assertAllTabs()
    capture("live-inbox-resolved")
  }

  func testBackgroundRecoveryPreservesDraftAndResumesLiveStream() async throws {
    _ = try await requireStreamFixture()
    app.launch()
    tap("connect-local")
    XCTAssertTrue(element("live-workspace-notice").waitForExistence(timeout: 15))
    openLiveSession(streamFixtureID)
    waitForConnectedStream()
    let token = UUID().uuidString
    let draft = "Unsent foreground recovery draft \(token)."
    tap("expand-composer")
    let editor = element("expanded-composer-input")
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText(draft)
    tap("composer-done")

    XCUIDevice.shared.press(.home)
    let backgrounded = XCTNSPredicateExpectation(
      predicate: NSPredicate { [app] _, _ in
        app?.state == .runningBackground || app?.state == .runningBackgroundSuspended
      }, object: app)
    XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 10), .completed)
    let backgroundText = "Committed while the app was backgrounded \(token)."
    let backgroundItem = try await postFixtureEvent(
      "external_conversation_item",
      data: [
        "item_type": "message", "response_id": "ui-background-\(token)",
        "item_data": [
          "role": "assistant", "agent": "Native UI fixture",
          "content": [["type": "output_text", "text": backgroundText]],
        ],
      ])
    let backgroundID = try XCTUnwrap(backgroundItem["item_id"] as? String)
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    waitForConnectedStream()
    XCTAssertTrue(element("message-text-\(backgroundID)").waitForExistence(timeout: 15))
    XCTAssertEqual(textMatches(backgroundText).count, 1)
    XCTAssertEqual(element("composer-input").value as? String, draft)

    // A transient event after activation proves the subscription resumed, not just history reload.
    let resumedText = "Live stream resumed after foregrounding \(token)."
    _ = try await postFixtureEvent(
      "external_output_text_delta",
      data: [
        "delta": resumedText, "message_id": "ui-foreground-\(token)", "index": 0,
        "final": true,
      ])
    XCTAssertTrue(text(resumedText).waitForExistence(timeout: 15))
    let resumedItem = try await postFixtureEvent(
      "external_conversation_item",
      data: [
        "item_type": "message", "response_id": "ui-foreground-\(token)",
        "item_data": [
          "role": "assistant", "agent": "Native UI fixture",
          "content": [["type": "output_text", "text": resumedText]],
        ],
      ])
    let resumedID = try XCTUnwrap(resumedItem["item_id"] as? String)
    XCTAssertTrue(element("message-text-\(resumedID)").waitForExistence(timeout: 15))
    XCTAssertEqual(textMatches(resumedText).count, 1)
    XCTAssertEqual(element("composer-input").value as? String, draft)
    let items = try await storedItems(sessionID: streamFixtureID)
    XCTAssertFalse(items.contains { $0["role"] as? String == "user" && itemText($0) == draft })
    capture("live-background-recovery")
  }

  func testUnboundNativeSessionKeepsDraftAndDisablesSend() async throws {
    let fixture = try await requireStreamFixture()
    guard fixture["harness"] as? String == "codex-native" else {
      throw failure("The readiness test requires the dedicated unbound native fixture.")
    }
    let before = try await storedItems(sessionID: streamFixtureID)
    app.launch()
    tap("connect-local")
    XCTAssertTrue(element("live-workspace-notice").waitForExistence(timeout: 15))
    openLiveSession(streamFixtureID)
    waitForConnectedStream()
    let unavailable = element("composer-unavailable-\(streamFixtureID)")
    XCTAssertTrue(unavailable.waitForExistence(timeout: 5))
    XCTAssertTrue(unavailable.label.contains("no execution connection"))
    XCTAssertTrue(unavailable.label.contains("New session"))
    XCTAssertTrue(unavailable.label.contains("connected host"))
    XCTAssertFalse(unavailable.label.contains("read-only"))
    XCTAssertFalse(text("The last response failed. Check the server or provider sign-in.").exists)
    let prompt = "Keep this unsent draft \(UUID().uuidString)."
    let composer = element("composer-input")
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    XCTAssertTrue(composer.isEnabled)
    composer.tap()
    composer.typeText(prompt)
    XCTAssertFalse(element("send-message").isEnabled)
    XCTAssertEqual(composer.value as? String, prompt)
    tap("expand-composer")
    XCTAssertTrue(element("expanded-composer-input").waitForExistence(timeout: 5))
    XCTAssertEqual(element("expanded-composer-input").value as? String, prompt)
    XCTAssertFalse(element("expanded-send-message").isEnabled)
    tap("expanded-composer-details")
    XCTAssertTrue(element("expanded-composer-unavailable").waitForExistence(timeout: 5))
    XCTAssertTrue(
      element("expanded-composer-unavailable").label.contains("no execution connection"))
    tap("composer-details-done")
    tap("composer-done")
    XCTAssertEqual(composer.value as? String, prompt)
    XCTAssertFalse(element("send-message").isEnabled)
    let after = try await storedItems(sessionID: streamFixtureID)
    XCTAssertEqual(
      after.compactMap { $0["id"] as? String }, before.compactMap { $0["id"] as? String })
    XCTAssertFalse(after.contains { $0["role"] as? String == "user" && itemText($0) == prompt })
    capture("live-unbound-native-send-unavailable")
  }

  func testOptInRealModelReplyArrivesWithoutRefresh() async throws {
    guard ProcessInfo.processInfo.environment["OMNI_LIVE_MODEL_UI_TESTS"] == "1" else {
      throw XCTSkip(
        "Set TEST_RUNNER_OMNI_LIVE_MODEL_UI_TESTS=1 for the explicit local model UI test.")
    }
    let sessionID = try await realModelSessionID()
    app.launch()
    tap("connect-local")
    XCTAssertTrue(element("live-workspace-notice").waitForExistence(timeout: 15))
    assertAllTabs()
    openLiveSession(sessionID)
    waitForConnectedStream()
    tap("expand-composer")
    let token = "OMNI_UI_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    let prompt = "Reply exactly: \(token)\nDo not call tools or access files."
    let editor = element("expanded-composer-input")
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText(prompt)
    tap("expanded-send-message")
    XCTAssertTrue(
      text(token).waitForExistence(timeout: 90),
      "Expected a real generated assistant reply, not an injected fixture.")
    XCTAssertEqual(textMatches(token).count, 1)
    let items = try await waitForStoredReply(token, sessionID: sessionID)
    let userItems = items.filter { $0["role"] as? String == "user" && itemText($0) == prompt }
    let replies = items.filter { $0["role"] as? String == "assistant" && itemText($0) == token }
    XCTAssertEqual(userItems.count, 1, "The prompt must be stored exactly once.")
    XCTAssertEqual(replies.count, 1, "The generated final reply must be stored exactly once.")
    let replyID = try XCTUnwrap(replies.first?["id"] as? String)
    XCTAssertTrue(element("message-text-\(replyID)").waitForExistence(timeout: 15))
    XCTAssertEqual(textMatches(token).count, 1)
    capture("live-real-model-reply")
  }

  func testOptInLiveCreationAndNativeFileSend() async throws {
    guard ProcessInfo.processInfo.environment["OMNI_LIVE_MODEL_UI_TESTS"] == "1" else {
      throw XCTSkip(
        "Set TEST_RUNNER_OMNI_LIVE_MODEL_UI_TESTS=1 and run bin/seed-picker-file.py first.")
    }
    let info = try await requestJSON(path: "/v1/info")
    let identity = try await requestJSON(path: "/v1/me")
    XCTAssertEqual(info["single_user"] as? Bool, true)
    XCTAssertEqual(info["accounts_enabled"] as? Bool, false)
    XCTAssertEqual(identity["user_id"] as? String, "local")
    let hosts = try await requestJSON(path: "/v1/hosts")
    let host = try XCTUnwrap(
      (hosts["hosts"] as? [[String: Any]])?.first {
        $0["status"] as? String == "online"
          && ($0["configured_harnesses"] as? [String: Any])?["codex-native"] as? Bool == true
      })
    let hostID = try XCTUnwrap(host["host_id"] as? String)
    let hostName = try XCTUnwrap(host["name"] as? String)
    let catalog = try await requestJSON(
      path: "/v1/agents", query: [URLQueryItem(name: "limit", value: "1000")])
    let agent = try XCTUnwrap(
      (catalog["data"] as? [[String: Any]])?.first {
        $0["harness"] as? String == "codex-native" && $0["builtin"] as? Bool == true
      })
    let agentName = try XCTUnwrap(agent["name"] as? String)
    let title = "Native E2E \(UUID().uuidString.prefix(8))"
    let token = "OMNI_CREATE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    let prompt = "Reply exactly: \(token)\nDo not call tools or access files."
    app.launch()
    tap("connect-local")
    XCTAssertTrue(element("live-workspace-notice").waitForExistence(timeout: 15))
    tap("new-session")
    tap("creation-host")
    app.buttons[hostName].firstMatch.tap()
    tap("creation-harness")
    app.buttons["Codex"].firstMatch.tap()
    tap("creation-agent")
    app.buttons[agentName].firstMatch.tap()
    enterCreationValue(runtimePath + "/chat-workspace", into: "creation-workspace")
    enterCreationValue(title, into: "new-session-title")
    enterCreationValue(prompt, into: "new-session-prompt")
    capture("live-create-ready")
    tap("create-session")
    XCTAssertTrue(element("composer-input").waitForExistence(timeout: 30))
    waitForConnectedStream()
    let page = try await requestJSON(
      path: "/v1/sessions",
      query: [
        URLQueryItem(name: "search_query", value: title),
        URLQueryItem(name: "limit", value: "1000"),
      ])
    let matches = (page["data"] as? [[String: Any]] ?? []).filter {
      $0["title"] as? String == title
    }
    XCTAssertEqual(matches.count, 1, "Creating once must produce exactly one session.")
    let sessionID = try XCTUnwrap(matches.first?["id"] as? String)
    let session = try await requestJSON(
      path: "/v1/sessions/\(sessionID)",
      query: [URLQueryItem(name: "include_items", value: "false")])
    XCTAssertEqual(session["workspace"] as? String, runtimePath + "/chat-workspace")
    XCTAssertEqual(session["host_id"] as? String, hostID)
    XCTAssertEqual(session["harness"] as? String, "codex-native")
    XCTAssertEqual(session["agent_name"] as? String, agentName)
    XCTAssertEqual(element("composer-input").value as? String, prompt)
    let beforeSend = try await storedItems(sessionID: sessionID)
    XCTAssertFalse(beforeSend.contains { $0["role"] as? String == "user" })
    tap("send-message")
    XCTAssertTrue(
      text(token).waitForExistence(timeout: 120), "The real harness must respond in the app.")
    let firstItems = try await waitForStoredReply(token, sessionID: sessionID)
    XCTAssertEqual(
      firstItems.filter { $0["role"] as? String == "user" && itemText($0) == prompt }.count, 1)
    XCTAssertEqual(
      firstItems.filter { $0["role"] as? String == "assistant" && itemText($0) == token }.count, 1)
    XCTAssertEqual(textMatches(token).count, 1)
    capture("live-created-session-reply")

    tap("composer-attachments")
    tap("attachment-pick-files")
    let browse = app.buttons["Browse"].firstMatch
    if browse.waitForExistence(timeout: 3) { browse.tap() }
    let local = app.staticTexts["On My iPhone"].firstMatch
    if local.waitForExistence(timeout: 3) { local.tap() }
    let file = app.descendants(matching: .any).matching(
      NSPredicate(format: "label BEGINSWITH %@", "Omni native attachment")
    ).firstMatch
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "native-files-picker"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    XCTAssertTrue(
      file.waitForExistence(timeout: 15),
      "Seed the real Files provider using bin/seed-picker-file.py.")
    file.tap()
    let open = app.buttons["Open"].firstMatch
    if open.waitForExistence(timeout: 3) { open.tap() }
    XCTAssertTrue(text("Uploaded · Ready to send").waitForExistence(timeout: 30))
    capture("live-file-uploaded")
    app.buttons["Done"].firstMatch.tap()
    tap("expand-composer")
    let filePrompt =
      "Read the attached text file and reply with only its contents, without quotes. Do not access other files."
    let editor = element("expanded-composer-input")
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText(filePrompt)
    tap("expanded-send-message")
    XCTAssertTrue(text("OMNI_FILE_PICKER_OK").waitForExistence(timeout: 120))
    let items = try await waitForStoredReply("OMNI_FILE_PICKER_OK", sessionID: sessionID)
    let inputs = items.filter { $0["role"] as? String == "user" && itemText($0) == filePrompt }
    XCTAssertEqual(inputs.count, 1)
    let blocks = try XCTUnwrap(inputs.first?["content"] as? [[String: Any]])
    let attachment = try XCTUnwrap(blocks.first { $0["type"] as? String == "input_file" })
    XCTAssertEqual(attachment["filename"] as? String, "Omni native attachment.txt")
    let fileID = try XCTUnwrap(attachment["file_id"] as? String)
    XCTAssertFalse(fileID.isEmpty)
    let fileURL = try XCTUnwrap(
      URL(
        string:
          "http://127.0.0.1:6767/v1/sessions/\(sessionID)/resources/files/\(fileID)/content"))
    let (bytes, response) = try await transport.data(from: fileURL)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(response.url, fileURL)
    XCTAssertEqual(bytes, Data("OMNI_FILE_PICKER_OK\n".utf8))
    XCTAssertEqual(
      items.filter { $0["role"] as? String == "assistant" && itemText($0) == "OMNI_FILE_PICKER_OK" }
        .count, 1)
    XCTAssertEqual(app.buttons["composer-attachments"].label, "Add attachments")
    capture("live-file-model-reply")
    let evidence = XCTAttachment(string: "Session: \(sessionID)\nTitle: \(title)\nFile: \(fileID)")
    evidence.name = "live-session-identifiers"
    evidence.lifetime = .keepAlways
    add(evidence)
  }

  private func enterCreationValue(_ value: String, into identifier: String) {
    let field = element(identifier)
    for _ in 0..<8 {
      if field.exists && field.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(field.exists && field.isHittable)
    field.tap()
    field.typeText(value)
    let done = app.buttons["creation-dismiss-keyboard"]
    if done.waitForExistence(timeout: 2) { done.tap() }
  }

  func testLiveConfigurationIdentityCatalogAndDetailsWithoutMutation() async throws {
    try await requireLocalFixture()
    let sessionID = try await realModelSessionID()
    let before = try await requestJSON(
      path: "/v1/sessions/\(sessionID)",
      query: [URLQueryItem(name: "include_items", value: "false")])
    let rawModel = try XCTUnwrap(
      before["model_override"] as? String ?? before["llm_model"] as? String)
    let harness = try XCTUnwrap(before["harness"] as? String)
    let agents = try await requestJSON(
      path: "/v1/agents", query: [URLQueryItem(name: "limit", value: "1000")])
    let currentTarget = try XCTUnwrap(
      (agents["data"] as? [[String: Any]] ?? []).first {
        $0["harness"] as? String == harness && $0["builtin"] as? Bool == true
      })
    let currentTargetID = try XCTUnwrap(currentTarget["id"] as? String)
    let models = before["model_options"] as? [[String: Any]] ?? []
    let matchingModel = models.first {
      $0["id"] as? String == rawModel || $0["model"] as? String == rawModel
    }
    let modelLabel = matchingModel?["displayName"] as? String ?? rawModel
    let beforeItems = try await storedItems(sessionID: sessionID)

    app.launch()
    tap("connect-local")
    XCTAssertTrue(element("live-workspace-notice").waitForExistence(timeout: 15))
    openLiveSession(sessionID)
    waitForConnectedStream()
    XCTAssertTrue(
      (app.buttons["composer-configuration"].value as? String ?? "").contains(modelLabel))
    tap("composer-configuration")
    XCTAssertTrue(element("configuration-current").label.contains(modelLabel))
    tap("configuration-model")
    XCTAssertEqual(element("model-current-value").label, modelLabel)
    if matchingModel == nil {
      XCTAssertTrue(
        text(rawModel).exists, "An unadvertised current ID must remain visible, not be guessed.")
    }
    tap("configuration-done")
    tap("expand-composer")
    let draft = "Unsent configuration inspection draft."
    let editor = element("expanded-composer-input")
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText(draft)
    tap("expanded-configuration")
    tap("configuration-harness")
    let currentHarness = app.buttons["harness-\(currentTargetID)"]
    revealConfigurationElement(currentHarness)
    XCTAssertTrue(currentHarness.waitForExistence(timeout: 15))
    XCTAssertFalse(currentHarness.isEnabled)
    tap("configuration-done")
    XCTAssertEqual(editor.value as? String, draft)
    tap("expanded-configuration")
    tap("configuration-details")
    XCTAssertTrue(text(harness).waitForExistence(timeout: 5))
    XCTAssertTrue(text(rawModel).exists)
    capture("live-picker-reported-identity-details")
    tap("configuration-done")
    XCTAssertEqual(editor.value as? String, draft)
    tap("composer-done")
    XCTAssertEqual(element("composer-input").value as? String, draft)
    let after = try await requestJSON(
      path: "/v1/sessions/\(sessionID)",
      query: [URLQueryItem(name: "include_items", value: "false")])
    for key in ["agent_id", "harness", "model_override", "reasoning_effort"] {
      XCTAssertEqual(
        before[key] as? String, after[key] as? String, "Inspection must not change \(key).")
    }
    let afterItems = try await storedItems(sessionID: sessionID)
    XCTAssertEqual(
      beforeItems.compactMap { $0["id"] as? String }, afterItems.compactMap { $0["id"] as? String })
  }

  func testOptInConfigurationMutationPreservesConversationAndRestoresHarness() async throws {
    guard ProcessInfo.processInfo.environment["OMNI_CONFIG_MUTATION_UI_TESTS"] == "1" else {
      throw XCTSkip(
        "Set TEST_RUNNER_OMNI_CONFIG_MUTATION_UI_TESTS=1 for isolated configuration writes.")
    }
    let sessionID = try await realModelSessionID(title: "Native configuration validation")
    let before = try await requestJSON(
      path: "/v1/sessions/\(sessionID)",
      query: [URLQueryItem(name: "include_items", value: "false")])
    guard before["status"] as? String == "idle", before["harness"] as? String == "codex-native",
      (before["pending_elicitations"] as? [[String: Any]] ?? []).isEmpty
    else {
      throw failure(
        "The dedicated configuration fixture must start idle on Codex with no pending requests.")
    }
    let originalAgent = try XCTUnwrap(before["agent_id"] as? String)
    let beforeItems = try await storedItems(sessionID: sessionID)
    let marker = "Stored configuration fixture. No model response was generated."
    let markerItem = try XCTUnwrap(beforeItems.first { itemText($0) == marker })
    let markerID = try XCTUnwrap(markerItem["id"] as? String)
    let models = try await configurationFixtureModels(before)
    let choice = try XCTUnwrap(
      models.first {
        $0["hidden"] as? Bool != true
          && ($0["model"] as? String ?? $0["id"] as? String) != before["model_override"] as? String
          && !($0["supportedReasoningEfforts"] as? [[String: Any]] ?? []).isEmpty
      })
    let modelID = try XCTUnwrap(choice["id"] as? String)
    let modelValue = try XCTUnwrap(choice["model"] as? String ?? choice["id"] as? String)
    let efforts = choice["supportedReasoningEfforts"] as? [[String: Any]] ?? []
    let effort = try XCTUnwrap(efforts.first?["reasoningEffort"] as? String)
    let agents = try await requestJSON(
      path: "/v1/agents", query: [URLQueryItem(name: "limit", value: "1000")])
    let originalBuiltin = try XCTUnwrap(
      (agents["data"] as? [[String: Any]] ?? []).first {
        $0["harness"] as? String == "codex-native" && $0["builtin"] as? Bool == true
      })
    let originalBuiltinID = try XCTUnwrap(originalBuiltin["id"] as? String)
    let target = try XCTUnwrap(
      (agents["data"] as? [[String: Any]] ?? []).first {
        ($0["name"] as? String)?.lowercased() == "polly" && $0["harness"] as? String == "claude-sdk"
          && $0["builtin"] as? Bool == true
      })
    let targetID = try XCTUnwrap(target["id"] as? String)

    app.launch()
    tap("connect-local")
    XCTAssertTrue(element("live-workspace-notice").waitForExistence(timeout: 15))
    openLiveSession(sessionID)
    waitForConnectedStream()
    tap("expand-composer")
    let draft = "Unsent draft retained through real configuration changes."
    let editor = element("expanded-composer-input")
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText(draft)
    tap("expanded-configuration")
    tap("configuration-model")
    tap("model-\(modelID)")
    tap("configuration-effort")
    tap("effort-\(effort)")
    tap("configuration-apply")
    waitUntilGone(app.buttons["configuration-done"])
    XCTAssertEqual(editor.value as? String, draft)
    let configured = try await requestJSON(
      path: "/v1/sessions/\(sessionID)",
      query: [URLQueryItem(name: "include_items", value: "false")])
    XCTAssertEqual(configured["model_override"] as? String, modelValue)
    XCTAssertEqual(configured["reasoning_effort"] as? String, effort)
    XCTAssertEqual(configured["agent_id"] as? String, originalAgent)

    tap("expanded-configuration")
    tap("configuration-harness")
    tap("harness-\(targetID)")
    tap("configuration-apply")
    confirmConfigurationHarnessSwitch()
    waitUntilGone(app.buttons["configuration-done"])
    XCTAssertEqual(editor.value as? String, draft)
    let switched = try await requestJSON(
      path: "/v1/sessions/\(sessionID)",
      query: [URLQueryItem(name: "include_items", value: "false")])
    XCTAssertEqual(switched["id"] as? String, sessionID)
    XCTAssertNotNil(switched["agent_id"] as? String)
    XCTAssertNotEqual(switched["agent_id"] as? String, originalAgent)
    XCTAssertEqual(switched["agent_name"] as? String, target["name"] as? String)
    XCTAssertEqual(switched["harness"] as? String, "claude-sdk")
    XCTAssertNil(switched["model_override"] as? String)
    XCTAssertNil(switched["reasoning_effort"] as? String)
    XCTAssertEqual(switched["workspace"] as? String, before["workspace"] as? String)
    tap("composer-done")
    XCTAssertTrue(element("message-text-\(markerID)").exists)
    capture("live-picker-cross-family-switch-retains-history")

    waitForConnectedStream()
    tap("composer-configuration")
    tap("configuration-harness")
    tap("harness-\(originalBuiltinID)")
    tap("configuration-apply")
    confirmConfigurationHarnessSwitch()
    waitUntilGone(app.buttons["configuration-done"])
    XCTAssertEqual(element("composer-input").value as? String, draft)
    let restored = try await requestJSON(
      path: "/v1/sessions/\(sessionID)",
      query: [URLQueryItem(name: "include_items", value: "false")])
    XCTAssertEqual(restored["agent_name"] as? String, originalBuiltin["name"] as? String)
    XCTAssertEqual(restored["harness"] as? String, "codex-native")
    XCTAssertNil(restored["model_override"] as? String)
    XCTAssertNil(restored["reasoning_effort"] as? String)
    let afterItems = try await storedItems(sessionID: sessionID)
    let previousIDs = Set(beforeItems.compactMap { $0["id"] as? String })
    XCTAssertTrue(previousIDs.isSubset(of: Set(afterItems.compactMap { $0["id"] as? String })))
    for previous in beforeItems {
      let retained = try XCTUnwrap(
        afterItems.first { $0["id"] as? String == previous["id"] as? String })
      XCTAssertEqual(retained as NSDictionary, previous as NSDictionary)
    }
    // Runtime teardown may append resource events, but never a message or model response.
    let added = afterItems.filter { !previousIDs.contains($0["id"] as? String ?? "") }
    XCTAssertTrue(added.allSatisfy { $0["type"] as? String == "resource_event" })
    XCTAssertFalse(afterItems.contains { itemText($0) == draft })
    capture("live-picker-harness-restored-no-prompt-sent")
  }

  private func confirmConfigurationHarnessSwitch() {
    let alert = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Switch to ")).firstMatch
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    let diagnostic = XCTAttachment(string: app.debugDescription)
    diagnostic.name = "harness-confirmation-hierarchy"
    diagnostic.lifetime = .deleteOnSuccess
    add(diagnostic)
    let identified = alert.descendants(matching: .any)
      .matching(identifier: "configuration-confirm-switch").firstMatch
    let confirm = identified.exists ? identified : alert.buttons["Switch harness"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    XCTAssertTrue(confirm.isEnabled && confirm.isHittable)
    confirm.tap()
  }

  func testOptInExternalConfigurationChangeRequiresReview() async throws {
    guard ProcessInfo.processInfo.environment["OMNI_CONFIG_MUTATION_UI_TESTS"] == "1" else {
      throw XCTSkip(
        "Set TEST_RUNNER_OMNI_CONFIG_MUTATION_UI_TESTS=1 for isolated configuration writes.")
    }
    let sessionID = try await realModelSessionID(title: "Native configuration validation")
    let before = try await requestJSON(
      path: "/v1/sessions/\(sessionID)",
      query: [URLQueryItem(name: "include_items", value: "false")])
    guard before["status"] as? String == "idle", before["harness"] as? String == "codex-native",
      (before["pending_elicitations"] as? [[String: Any]] ?? []).isEmpty
    else {
      throw failure("The conflict fixture must start idle on Codex with no pending requests.")
    }
    let beforeItems = try await storedItems(sessionID: sessionID)
    guard
      beforeItems.contains(where: {
        itemText($0) == "Stored configuration fixture. No model response was generated."
      })
    else { throw failure("Refusing a configuration write without the dedicated fixture marker.") }
    let initialModels = Set(
      [before["model_override"] as? String, before["llm_model"] as? String].compactMap { $0 })
    let choices = try await configurationFixtureModels(before).filter {
      $0["hidden"] as? Bool != true && $0["id"] as? String != nil
        && Set([$0["model"] as? String, $0["id"] as? String].compactMap { $0 })
          .isDisjoint(with: initialModels)
    }
    let staged = try XCTUnwrap(choices.first, "The fixture needs an alternative model to stage.")
    let stagedID = try XCTUnwrap(staged["id"] as? String)
    let stagedValue = try XCTUnwrap(staged["model"] as? String ?? staged["id"] as? String)
    let external = try XCTUnwrap(
      choices.first {
        ($0["model"] as? String ?? $0["id"] as? String) != stagedValue
          && $0["id"] as? String != stagedID
      }, "The fixture needs another distinct advertised model for the external edit.")
    let externalValue = try XCTUnwrap(external["model"] as? String ?? external["id"] as? String)
    let externalLabel = external["displayName"] as? String ?? externalValue

    app.launch()
    tap("connect-local")
    XCTAssertTrue(element("live-workspace-notice").waitForExistence(timeout: 15))
    openLiveSession(sessionID)
    waitForConnectedStream()
    tap("expand-composer")
    let draft = "Keep this unsent draft during a settings conflict."
    let editor = element("expanded-composer-input")
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText(draft)
    tap("expanded-configuration")
    tap("configuration-model")
    tap("model-\(stagedID)")
    XCTAssertTrue(app.buttons["configuration-apply"].isEnabled)

    // Only this verified disposable fixture receives the simulated second-client edit.
    _ = try await requestJSON(
      path: "/v1/sessions/\(sessionID)", method: "PATCH",
      body: ["model_override": externalValue])
    XCTAssertTrue(element("configuration-conflict").waitForExistence(timeout: 15))
    let confirmedIdentity = element("configuration-current").label
    XCTAssertTrue(
      confirmedIdentity.contains(externalLabel) || confirmedIdentity.contains(externalValue),
      "Confirmed identity must show the external model, using its raw ID without a runner catalog.")
    XCTAssertFalse(app.buttons["configuration-apply"].isEnabled)
    capture("live-picker-external-change-blocks-stale-edits")
    tap("configuration-review")
    waitUntilGone(element("configuration-conflict"))
    XCTAssertTrue(app.buttons["configuration-model"].label.contains(externalLabel))
    XCTAssertFalse(app.buttons["configuration-apply"].isEnabled)
    tap("configuration-model")
    tap("model-default")
    tap("configuration-effort")
    tap("effort-default")
    tap("configuration-apply")
    waitUntilGone(app.buttons["configuration-done"])
    XCTAssertEqual(editor.value as? String, draft)
    let after = try await requestJSON(
      path: "/v1/sessions/\(sessionID)",
      query: [URLQueryItem(name: "include_items", value: "false")])
    XCTAssertNil(after["model_override"] as? String)
    XCTAssertNil(after["reasoning_effort"] as? String)
    XCTAssertEqual(after["harness"] as? String, "codex-native")
    let afterItems = try await storedItems(sessionID: sessionID)
    XCTAssertEqual(
      Set(beforeItems.compactMap { $0["id"] as? String }),
      Set(afterItems.compactMap { $0["id"] as? String }))
    XCTAssertFalse(afterItems.contains { itemText($0) == draft })
  }

  private func revealConfigurationElement(_ element: XCUIElement) {
    let list = app.collectionViews.firstMatch
    for _ in 0..<20 {
      if element.exists { return }
      list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        .press(
          forDuration: 0.1,
          thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
    }
    for _ in 0..<20 {
      if element.exists { return }
      list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        .press(
          forDuration: 0.1,
          thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
    }
  }

  private func configurationFixtureModels(_ snapshot: [String: Any]) async throws -> [[String: Any]]
  {
    let models = snapshot["model_options"] as? [[String: Any]] ?? []
    if !models.isEmpty { return models }
    guard snapshot["title"] as? String == "Native configuration validation",
      snapshot["workspace"] as? String == runtimePath + "/chat-workspace",
      snapshot["harness"] as? String == "codex-native", snapshot["host_online"] as? Bool == true,
      let host = snapshot["host_id"] as? String,
      host.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    else { throw failure("Host catalog preview requires the verified isolated Codex fixture.") }
    let preview = try await requestJSON(
      path: "/v1/hosts/\(host)/harnesses/codex-native/model-options")
    return try XCTUnwrap(preview["models"] as? [[String: Any]])
  }

  func testUnavailableServerKeepsDemoAnExplicitChoice() {
    app.launch()
    let field = element("local-server-url")
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    let value = field.value as? String ?? ""
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
    field.typeText("http://127.0.0.1:6768")
    tap("connect-local")
    XCTAssertTrue(element("connection-error").waitForExistence(timeout: 20))
    XCTAssertFalse(element("live-workspace-notice").exists)
    tap("open-demo")
    XCTAssertTrue(app.buttons["session-row-demo-design"].waitForExistence(timeout: 10))
  }

  func testDemoDraftSurvivesLiveModeRoundTrip() async throws {
    try await requireLocalFixture()
    app.launch()
    tap("open-demo")
    tap("session-row-demo-design")
    tap("expand-composer")
    let draft = "Keep this offline draft separate from the real server."
    let editor = element("expanded-composer-input")
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText(draft)
    tap("composer-done")
    let back = app.navigationBars.buttons.element(boundBy: 0)
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.tap()
    app.tabBars.buttons["Settings"].tap()
    capture("demo-settings-before-live")
    tap("connect-local")
    XCTAssertTrue(element("live-workspace-notice").waitForExistence(timeout: 15))
    app.tabBars.buttons["Settings"].tap()
    tap("use-demo")
    tap("session-row-demo-design")
    tap("expand-composer")
    XCTAssertEqual(element("expanded-composer-input").value as? String, draft)
  }

  private func requireLocalFixture() async throws {
    var request = URLRequest(
      url: URL(string: "http://127.0.0.1:6767/v1/sessions/\(fixtureID)/items?limit=1&order=desc")!)
    request.timeoutInterval = 3
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200,
        String(data: data, encoding: .utf8)?.contains("Local API fixture message 60.") == true
      else {
        throw XCTSkip("Start the isolated local server and run bin/seed-local-fixtures.py first.")
      }
    } catch let skip as XCTSkip {
      throw skip
    } catch {
      throw XCTSkip("Local fixture server unavailable. See NativeLab README for setup.")
    }
  }

  private var runtimePath: String {
    var repo = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repo.deleteLastPathComponent() }
    return repo.appendingPathComponent(".native-lab-server").path
  }

  private func requireStreamFixture() async throws -> [String: Any] {
    let fixture: [String: Any]
    do {
      fixture = try await requestJSON(
        path: "/v1/sessions/\(streamFixtureID)",
        query: [URLQueryItem(name: "include_items", value: "false")])
    } catch {
      throw XCTSkip(
        "Start the isolated local server and run bin/seed-local-fixtures.py for live UI tests.")
    }
    let info = try await requestJSON(path: "/v1/info")
    let identity = try await requestJSON(path: "/v1/me")
    guard info["single_user"] as? Bool == true, info["accounts_enabled"] as? Bool == false,
      identity["user_id"] as? String == "local",
      fixture["id"] as? String == streamFixtureID,
      fixture["title"] as? String == "Live stream validation",
      fixture["workspace"] as? String == runtimePath,
      fixture["runner_id"] == nil || fixture["runner_id"] is NSNull,
      fixture["host_id"] == nil || fixture["host_id"] is NSNull
    else {
      throw failure(
        "Refusing fixture events: expected the dedicated local, unbound Live stream validation session."
      )
    }
    verifiedStreamFixture = true
    return fixture
  }

  private func postFixtureEvent(_ type: String, data: [String: Any]) async throws -> [String: Any] {
    guard verifiedStreamFixture,
      [
        "external_output_text_delta", "external_conversation_item", "external_session_status",
        "mcp_elicitation",
      ].contains(type)
    else {
      throw failure("Only explicit no-model fixture events are allowed in this helper.")
    }
    let acknowledgement = try await requestJSON(
      path: "/v1/sessions/\(streamFixtureID)/events", method: "POST",
      body: ["type": type, "data": data], expectedStatus: 202)
    XCTAssertEqual(acknowledgement["queued"] as? Bool, false)
    return acknowledgement
  }

  private func realModelSessionID(title: String = "Native live chat") async throws -> String {
    let info = try await requestJSON(path: "/v1/info")
    let identity = try await requestJSON(path: "/v1/me")
    guard info["single_user"] as? Bool == true, info["accounts_enabled"] as? Bool == false,
      identity["user_id"] as? String == "local"
    else { throw failure("The opt-in model test requires the isolated local single-user server.") }
    var cursor: String?
    var seen: Set<String> = []
    var candidates: [String] = []
    for _ in 0..<20 {
      var query = [URLQueryItem(name: "limit", value: "1000")]
      if let cursor { query.append(URLQueryItem(name: "after", value: cursor)) }
      let page = try await requestJSON(path: "/v1/sessions", query: query)
      for summary in page["data"] as? [[String: Any]] ?? [] {
        guard summary["title"] as? String == title,
          summary["workspace"] as? String == runtimePath + "/chat-workspace",
          let id = summary["id"] as? String
        else { continue }
        let snapshot = try await requestJSON(
          path: "/v1/sessions/\(id)", query: [URLQueryItem(name: "include_items", value: "false")])
        // An online host wakes a stopped runner when the native app sends.
        if snapshot["host_online"] as? Bool == true,
          let host = snapshot["host_id"] as? String, !host.isEmpty
        {
          guard ["idle", "failed"].contains(snapshot["status"] as? String ?? "") else {
            throw failure(
              "The dedicated \(title) session must not have an active turn before this test."
            )
          }
          candidates.append(id)
        }
      }
      if page["has_more"] as? Bool != true { break }
      guard let next = page["last_id"] as? String, seen.insert(next).inserted else {
        throw failure("The server returned invalid session pagination during model-test discovery.")
      }
      cursor = next
    }
    guard candidates.count == 1, let sessionID = candidates.first else {
      throw failure(
        "Expected exactly one \(title) session with an online host in the isolated chat workspace; found \(candidates.count)."
      )
    }
    return sessionID
  }

  private func storedItems(sessionID: String) async throws -> [[String: Any]] {
    let page = try await requestJSON(
      path: "/v1/sessions/\(sessionID)/items",
      query: [
        URLQueryItem(name: "limit", value: "1000"), URLQueryItem(name: "order", value: "desc"),
      ])
    return try XCTUnwrap(page["data"] as? [[String: Any]])
  }

  private func waitForStoredReply(_ text: String, sessionID: String) async throws -> [[String: Any]]
  {
    let deadline = Date().addingTimeInterval(30)
    repeat {
      let items = try await storedItems(sessionID: sessionID)
      if items.contains(where: { $0["role"] as? String == "assistant" && itemText($0) == text }) {
        return items
      }
      try await Task.sleep(for: .milliseconds(250))
    } while Date() < deadline
    throw failure(
      "The visible assistant reply was not committed to server history within 30 seconds.")
  }

  private func itemText(_ item: [String: Any]) -> String {
    if let text = item["content"] as? String { return text }
    return (item["content"] as? [[String: Any]] ?? [])
      .compactMap { $0["text"] as? String }.joined(separator: "\n")
  }

  private func requestJSON(
    path: String, query: [URLQueryItem] = [], method: String = "GET",
    body: [String: Any]? = nil, expectedStatus: Int = 200
  ) async throws -> [String: Any] {
    var components = URLComponents(string: "http://127.0.0.1:6767")!
    components.path = path
    components.queryItems = query.isEmpty ? nil : query
    let url = try XCTUnwrap(components.url)
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpShouldHandleCookies = false
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await transport.data(for: request)
    guard let http = response as? HTTPURLResponse, http.url == url,
      http.statusCode == expectedStatus
    else {
      throw failure(
        "Local test request \(method) \(path) returned an unexpected response (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))."
      )
    }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func failure(_ message: String) -> NSError {
    return NSError(
      domain: "NativeLabLiveUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  private func assertAllTabs(file: StaticString = #filePath, line: UInt = #line) {
    for title in ["Sessions", "Inbox", "Settings"] {
      XCTAssertTrue(
        app.tabBars.buttons[title].exists, "Expected persistent \(title) tab.", file: file,
        line: line)
    }
  }

  private func waitForConnectedStream() {
    let status = element("conversation-connection-status")
    XCTAssertTrue(status.waitForExistence(timeout: 15))
    let connected = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "Connected"), object: status)
    XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 20), .completed)
  }

  private func openLiveSession(_ sessionID: String) {
    let row = app.buttons["session-row-\(sessionID)"].firstMatch
    let more = app.buttons["load-more-sessions"].firstMatch
    let list = app.collectionViews.firstMatch
    XCTAssertTrue(list.waitForExistence(timeout: 10))
    for _ in 0..<40 {
      for _ in 0..<16 {
        if row.exists || more.exists { break }
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
          .press(
            forDuration: 0.1,
            thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
      }
      if row.exists {
        tap("session-row-\(sessionID)")
        return
      }
      if !more.exists {
        // Returning from a conversation can leave already-loaded rows above this viewport.
        for _ in 0..<16 {
          if row.exists { break }
          list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .press(
              forDuration: 0.1,
              thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        }
        if row.exists {
          tap("session-row-\(sessionID)")
          return
        }
        break
      }
      tap("load-more-sessions")
      let loaded = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == false OR enabled == true"), object: more)
      XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 15), .completed)
    }
    XCTFail("Expected fixture session \(sessionID) to be reachable through session pagination.")
  }

  private func goBack() {
    let back = app.navigationBars.buttons.element(boundBy: 0)
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.tap()
  }

  private func textMatches(_ value: String) -> XCUIElementQuery {
    app.staticTexts.matching(NSPredicate(format: "label == %@", value))
  }

  private func text(_ value: String) -> XCUIElement { textMatches(value).firstMatch }

  private func waitUntilGone(_ element: XCUIElement) {
    let gone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 15), .completed)
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func message(_ index: Int) -> XCUIElement {
    app.staticTexts.matching(
      NSPredicate(format: "label == %@", String(format: "Local API fixture message %02d.", index))
    ).firstMatch
  }

  private func tap(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
    let button = app.buttons[identifier].firstMatch
    _ = button.waitForExistence(timeout: 5)
    if !button.exists || !button.isHittable {
      let list = app.collectionViews.firstMatch
      let container = list.exists ? list : app.scrollViews.firstMatch
      // Small drags avoid skipping a short control between the fixed bars on an SE.
      for (start, end) in [(0.65, 0.45), (0.4, 0.6)] {
        for _ in 0..<10 {
          if button.exists && button.isHittable { break }
          if list.exists {
            container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: start))
              .press(
                forDuration: 0.1,
                thenDragTo: container.coordinate(
                  withNormalizedOffset: CGVector(dx: 0.5, dy: end)))
          } else if start > end {
            // ScrollView frames can extend behind the keyboard; use its hittable area.
            container.swipeUp()
          } else {
            container.swipeDown()
          }
        }
        if button.exists && button.isHittable { break }
      }
    }
    XCTAssertTrue(button.exists, file: file, line: line)
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: button)
    let result = XCTWaiter.wait(for: [ready], timeout: 10)
    if result != .completed {
      let diagnostic = XCTAttachment(string: app.debugDescription)
      diagnostic.name = "unavailable-action-\(identifier)"
      diagnostic.lifetime = .keepAlways
      add(diagnostic)
      capture("unavailable-action-\(identifier)")
    }
    XCTAssertEqual(result, .completed, file: file, line: line)
    button.tap()
  }

  private func reveal(_ target: XCUIElement, in container: XCUIElement) {
    for _ in 0..<18 {
      if target.exists && target.isHittable { return }
      container.swipeDown()
    }
    XCTFail("Expected older history control or message to become visible.")
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

private final class FixtureTransportDelegate: NSObject, URLSessionTaskDelegate {
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
