import Foundation
import XCTest

@testable import NativeLabCore

final class LocalServerSessionClientTests: XCTestCase {
  func testChangedFilesInvalidationFetchesSessionScopedDetailsWithoutPolling() async throws {
    let harness = TransportHarness()
    harness.respond(
      path: "/v1/sessions/conv_a/resources/environments/default/changes",
      body: #"{"entries":[{"path":"Sources/App.swift","status":"modified"}]}"#)
    let client = try harness.makeClient()
    _ = try await client.connect()
    await client.primeEventReducerForTesting("conv_a")
    let updates = await client.updates()
    let received = expectation(description: "Changed file details published")
    let observer = Task {
      for await snapshot in updates {
        if snapshot.eventState?.sections.contains(where: { section in
          section.id == "files-default"
            && section.details.contains(where: { $0.title == "Sources/App.swift" })
        }) == true {
          received.fulfill()
          break
        }
      }
    }
    await client.invalidateChangedFiles(sessionID: "conv_a", environmentID: "default")
    await fulfillment(of: [received], timeout: 3)
    observer.cancel()
    XCTAssertEqual(harness.requests.filter { $0.url?.path.hasSuffix("/changes") == true }.count, 1)
    XCTAssertFalse(harness.requests.contains { $0.httpMethod != "GET" })
    await client.stopWatching()
  }

  func testChangedFilesFailureIsVisibleAndWrongSessionNeverFetches() async throws {
    let harness = TransportHarness()
    let client = try harness.makeClient()
    _ = try await client.connect()
    await client.primeEventReducerForTesting("conv_a")
    await client.invalidateChangedFiles(sessionID: "other", environmentID: "default")
    XCTAssertEqual(harness.requests.count, 2)
    let updates = await client.updates()
    let received = expectation(description: "Changed file failure published")
    let observer = Task {
      for await snapshot in updates {
        if snapshot.eventState?.sections.contains(where: {
          $0.id == "files-default" && $0.summary.contains("unavailable")
        }) == true {
          received.fulfill()
          break
        }
      }
    }
    await client.invalidateChangedFiles(sessionID: "conv_a", environmentID: "default")
    await fulfillment(of: [received], timeout: 3)
    observer.cancel()
    await client.stopWatching()
  }

  func testStructuredFormPostsTypedContentWithoutCoercion() async throws {
    let harness = TransportHarness()
    harness.writableSession(
      pending:
        #"[{"elicitation_id":"form1","params":{"requestedSchema":{"type":"object","required":["name","count","enabled","scope"],"properties":{"name":{"type":"string"},"count":{"type":"integer","minimum":1},"enabled":{"type":"boolean"},"scope":{"type":"array","items":{"type":"string","enum":["A","B"]}}}}}}]"#
    )
    harness.respond(
      path: "/v1/sessions/conv_a/elicitations/form1/resolve", body: #"{"queued":false}"#,
      status: 202)
    let client = try harness.makeClient()
    _ = try await client.connect()
    try await client.resolve(
      decisionID: "form1", sessionID: "conv_a",
      response: .form([
        "name": .string("Exact answer"), "count": .number(2), "enabled": .boolean(false),
        "scope": .strings(["A", "B"]),
      ]))
    let request = try XCTUnwrap(harness.requests.first { $0.httpMethod == "POST" })
    let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody)).object
    XCTAssertEqual(body?["action"], .string("accept"))
    XCTAssertEqual(
      body?["content"]?.object,
      [
        "name": .string("Exact answer"), "count": .number(2), "enabled": .bool(false),
        "scope": .array([.string("A"), .string("B")]),
      ])
  }

  func testInvalidStructuredFormDoesNotPostOrBecomeApproval() async throws {
    let harness = TransportHarness()
    harness.writableSession(
      pending:
        #"[{"elicitation_id":"form1","params":{"requestedSchema":{"type":"object","required":["count"],"properties":{"count":{"type":"integer","minimum":1}}}}}]"#
    )
    let client = try harness.makeClient()
    _ = try await client.connect()
    for response in [
      DecisionResponse.form(["count": .number(0)]), .form(["count": .string("2")]), .form([:]),
      .approve,
    ] {
      do {
        try await client.resolve(decisionID: "form1", sessionID: "conv_a", response: response)
        XCTFail("Invalid form submitted")
      } catch { XCTAssertEqual(error as? SessionClientError, .invalidDecision) }
    }
    XCTAssertFalse(harness.requests.contains { $0.httpMethod == "POST" })
  }

  func testExplicitPermissionResponsesMatchMainAppWire() async throws {
    let fixtures: [(String, DecisionResponse, [String: JSONValue])] = [
      (#"{"allow_all_edits":true}"#, .approveAllEdits, ["allow_all_edits": .bool(true)]),
      (#"{"remember_scope":{"tool":"Read"}}"#, .approveRemembering, ["remember": .bool(true)]),
      (
        #"{"exit_plan_mode":{"plan":"Review this plan"}}"#,
        .declineWithFeedback("Use a smaller change"), ["feedback": .string("Use a smaller change")]
      ),
      (
        #"{"command":"swift test","phase":"codex_command_approval","execpolicy_amendment":["swift","test"]}"#,
        .approveCommandPolicy(["swift", "test"]),
        ["execpolicy_amendment": .array([.string("swift"), .string("test")])]
      ),
    ]
    for (params, response, expected) in fixtures {
      let harness = TransportHarness()
      harness.writableSession(
        pending: "[{\"elicitation_id\":\"permission1\",\"params\":\(params)}]")
      harness.respond(
        path: "/v1/sessions/conv_a/elicitations/permission1/resolve", body: #"{"queued":false}"#,
        status: 202)
      let client = try harness.makeClient()
      _ = try await client.connect()
      try await client.resolve(decisionID: "permission1", sessionID: "conv_a", response: response)
      let request = try XCTUnwrap(harness.requests.first { $0.httpMethod == "POST" })
      let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody)).object
      XCTAssertEqual(body?["content"]?.object, expected)
      XCTAssertEqual(body?["action"], .string(expected["feedback"] == nil ? "accept" : "decline"))
    }
  }

  func testUnadvertisedPermissionOptionsNeverPost() async throws {
    let harness = TransportHarness()
    harness.writableSession(
      pending: #"[{"elicitation_id":"permission1","params":{"requestedSchema":{}}}]"#)
    let client = try harness.makeClient()
    _ = try await client.connect()
    for response in [
      DecisionResponse.approveAllEdits, .approveRemembering, .approveCommandPolicy(["swift"]),
      .declineWithFeedback("feedback"),
    ] {
      do {
        try await client.resolve(decisionID: "permission1", sessionID: "conv_a", response: response)
        XCTFail("Unadvertised permission submitted")
      } catch { XCTAssertEqual(error as? SessionClientError, .invalidDecision) }
    }
    XCTAssertFalse(harness.requests.contains { $0.httpMethod == "POST" })
  }

  func testTransientHydrationFailureReopensSSEAutomatically() async throws {
    let harness = TransportHarness()
    let reconnected = expectation(description: "Fresh SSE request after transient snapshot failure")
    harness.observeRequests { request in
      if request.url?.path == "/v1/sessions/conv_a/stream" { reconnected.fulfill() }
    }
    let client = try harness.makeClient()
    _ = try await client.connect()
    let activities = await client.activityUpdates()
    var iterator = activities.makeAsyncIterator()
    await client.primeStreamForTesting("conv_a")
    await client.failHydrationForTesting(.transport(URLError.networkConnectionLost.rawValue))
    let state = await iterator.next()
    XCTAssertEqual(state, .streamState(sessionID: "conv_a", state: .reconnecting))
    await fulfillment(of: [reconnected], timeout: 3)
    await client.stopWatching()
  }

  func testAuthenticationHydrationFailureStopsInsteadOfRetrying() async throws {
    let harness = TransportHarness()
    let client = try harness.makeClient()
    _ = try await client.connect()
    let activities = await client.activityUpdates()
    var iterator = activities.makeAsyncIterator()
    await client.primeStreamForTesting("conv_a")
    await client.failHydrationForTesting(.unauthorized)
    let state = await iterator.next()
    guard case .streamState("conv_a", .failed) = state else {
      return XCTFail("Expected stopped authentication failure")
    }
    XCTAssertEqual(harness.requests.count, 2)
    await client.stopWatching()
  }

  func testOptInLocalSSEAndWebSocketBecomeLiveWithoutPolling() async throws {
    guard ProcessInfo.processInfo.environment["OMNI_LOCAL_API_TESTS"] == "1" else {
      throw XCTSkip("Set OMNI_LOCAL_API_TESTS=1 to validate actual local streams.")
    }
    let client = try LocalServerSessionClient(
      baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:6767")))
    _ = try await client.connect()
    let sessionID = "f1000000000000000000000000000001"
    let sseReady = expectation(description: "SSE heartbeat and hydration ready")
    let socketReady = expectation(description: "WebSocket watch snapshot ready")
    let activities = await client.activityUpdates()
    let observer = Task {
      var sawSSE = false
      var sawSocket = false
      for await activity in activities {
        if case .streamState(let id, .live) = activity, id == sessionID, !sawSSE {
          sawSSE = true
          sseReady.fulfill()
        }
        if case .listState(.live) = activity, !sawSocket {
          sawSocket = true
          socketReady.fulfill()
        }
        if sawSSE && sawSocket { break }
      }
    }
    try await client.startSessionListUpdates(sessionIDs: [sessionID])
    try await client.startWatching(sessionID: sessionID)
    await fulfillment(of: [sseReady, socketReady], timeout: 8)
    await client.stopWatching()
    await client.stopSessionListUpdates()
    observer.cancel()
  }

  func testSubmitUsesRealMessageWireAndRetainsAcceptedQueueIdentity() async throws {
    let harness = TransportHarness()
    harness.writableSession()
    harness.respond(
      path: "/v1/sessions/conv_a/events",
      body: #"{"queued":true,"item_id":"item1","pending_id":"pending1"}"#, status: 202)
    let client = try harness.makeClient()
    _ = try await client.connect()
    await client.primeStreamForTesting("conv_a")
    let result = try await client.submitMessage(" Exact draft\n", to: "conv_a")
    XCTAssertTrue(result.queued)
    XCTAssertEqual(result.itemID, "item1")
    XCTAssertEqual(result.pendingID, "pending1")
    XCTAssertFalse(result.denied)
    let posts = harness.requests.filter { $0.httpMethod == "POST" }
    XCTAssertEqual(posts.count, 1)
    let request = try XCTUnwrap(posts.first)
    let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody)).object
    XCTAssertEqual(body?["type"]?.string, "message")
    XCTAssertEqual(body?["data"]?.object?["role"]?.string, "user")
    XCTAssertEqual(
      body?["data"]?.object?["content"]?.array?.first?.object?["text"]?.string, " Exact draft\n")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
  }

  func testSendRequiresHydratedLiveStreamAndDoesNotRetryUncertainPOST() async throws {
    let harness = TransportHarness()
    harness.writableSession()
    let client = try harness.makeClient()
    _ = try await client.connect()
    await expect(.streamNotReady) { _ = try await client.submitMessage("Hello", to: "conv_a") }
    XCTAssertFalse(harness.requests.contains { $0.httpMethod == "POST" })
    await client.primeStreamForTesting("conv_a")
    harness.fail(path: "/v1/sessions/conv_a/events", code: .networkConnectionLost)
    await expect(.deliveryUncertain) { _ = try await client.submitMessage("Hello", to: "conv_a") }
    XCTAssertEqual(harness.requests.filter { $0.httpMethod == "POST" }.count, 1)
  }

  func testDeniedAndMalformedAcknowledgementsAreNotSuccess() async throws {
    let harness = TransportHarness()
    harness.writableSession()
    let client = try harness.makeClient()
    _ = try await client.connect()
    await client.primeStreamForTesting("conv_a")
    harness.respond(
      path: "/v1/sessions/conv_a/events", body: #"{"queued":false,"denied":true}"#, status: 202)
    let denied = try await client.submitMessage("Hello", to: "conv_a")
    XCTAssertTrue(denied.denied)
    harness.respond(path: "/v1/sessions/conv_a/events", body: "{}", status: 202)
    await expect(.deliveryUncertain) { _ = try await client.submitMessage("Hello", to: "conv_a") }
    XCTAssertEqual(harness.requests.filter { $0.httpMethod == "POST" }.count, 2)
  }

  func testInterruptUsesInterruptNotOwnerStopSession() async throws {
    let harness = TransportHarness()
    harness.writableSession()
    harness.respond(path: "/v1/sessions/conv_a/events", body: #"{"queued":false}"#, status: 202)
    let client = try harness.makeClient()
    _ = try await client.connect()
    try await client.interrupt(sessionID: "conv_a")
    let request = try XCTUnwrap(harness.requests.first { $0.httpMethod == "POST" })
    let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody)).object
    XCTAssertEqual(body?["type"]?.string, "interrupt")
  }

  func testQuestionResolutionUsesRequestedAnswerKey() async throws {
    let harness = TransportHarness()
    harness.writableSession(
      pending:
        #"[{"elicitation_id":"ask1","params":{"message":"Choose","requestedSchema":{"properties":{"choice":{"type":"string","enum":["A","B"]}}}}}]"#
    )
    harness.respond(
      path: "/v1/sessions/conv_a/elicitations/ask1/resolve", body: #"{"queued":false}"#, status: 202
    )
    let client = try harness.makeClient()
    _ = try await client.connect()
    try await client.resolve(decisionID: "ask1", sessionID: "conv_a", response: .answer("B"))
    let request = try XCTUnwrap(harness.requests.first { $0.httpMethod == "POST" })
    let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody)).object
    XCTAssertEqual(body?["action"]?.string, "accept")
    XCTAssertEqual(body?["content"]?.object?["choice"]?.string, "B")
    XCTAssertNil(body?["content"]?.object?["answers"])
  }

  func testTypedQuestionNeverPostsBinaryApproval() async throws {
    let harness = TransportHarness()
    harness.writableSession(
      pending:
        #"[{"elicitation_id":"ask1","params":{"message":"Answer","requestedSchema":{"properties":{"name":{"type":"string"}}}}}]"#
    )
    let client = try harness.makeClient()
    _ = try await client.connect()
    do {
      try await client.resolve(decisionID: "ask1", sessionID: "conv_a", response: .approve)
      XCTFail("Typed forms must not become a binary approval")
    } catch {
      XCTAssertEqual(error as? SessionClientError, .invalidDecision)
    }
    XCTAssertFalse(harness.requests.contains { $0.httpMethod == "POST" })
  }

  func testPermissionCapabilitiesAndProviderFailureMetadata() async throws {
    let harness = TransportHarness()
    harness.respond(
      path: "/v1/sessions/conv_a",
      body:
        #"{"id":"conv_a","status":"failed","created_at":1,"permission_level":2,"last_task_error":{"code":"codex_reauth_required","message":"Sign in again"}}"#
    )
    harness.respond(path: "/v1/sessions/conv_a/items", body: #"{"data":[],"has_more":false}"#)
    let client = try harness.makeClient()
    _ = try await client.connect()
    let snapshot = try await client.conversation(id: "conv_a")
    XCTAssertFalse(snapshot.session.isReadOnly)
    XCTAssertTrue(snapshot.session.canRename)
    XCTAssertTrue(snapshot.session.canPin)
    XCTAssertFalse(snapshot.session.canArchive)
    XCTAssertEqual(snapshot.session.failureMessage, "Sign in again")
    XCTAssertEqual(snapshot.session.status, .idle)
    do {
      try await client.editSession("conv_a", change: .archived(true))
      XCTFail("Editor cannot archive")
    } catch { XCTAssertEqual(error as? SessionClientError, .readOnly) }
    XCTAssertFalse(harness.requests.contains { $0.httpMethod == "PATCH" })
  }

  func testListFramesUpdatePermissionsAndRemoveLostAccess() async throws {
    let harness = TransportHarness()
    let client = try harness.makeClient()
    _ = try await client.connect()
    let activities = await client.activityUpdates()
    var iterator = activities.makeAsyncIterator()
    try await client.handleListMessage(
      Data(
        #"{"type":"changed","items":[{"id":"conv_a","status":"running","created_at":1,"permission_level":4}]}"#
          .utf8))
    let changed = await iterator.next()
    guard case .sessionsChanged(let sessions) = changed else {
      return XCTFail("Expected list delta")
    }
    XCTAssertEqual(sessions.map(\.id), ["conv_a"])
    XCTAssertFalse(sessions[0].isReadOnly)
    _ = await iterator.next()  // Inventory invalidation.
    try await client.handleListMessage(Data(#"{"type":"removed","ids":["conv_a"]}"#.utf8))
    let removed = await iterator.next()
    XCTAssertEqual(removed, .sessionsRemoved(["conv_a"]))
  }

  func testPersistedRunnerFailureRemainsReadableAfterReopeningWithoutLastTaskError() async throws {
    let harness = TransportHarness()
    harness.respond(
      path: "/v1/sessions/conv_a",
      body:
        #"{"id":"conv_a","status":"failed","created_at":1,"permission_level":4,"last_task_error":null}"#
    )
    harness.respond(
      path: "/v1/sessions/conv_a/items",
      body:
        #"{"data":[{"id":"error_1","type":"error","response_id":"turn_1","source":"execution","code":"runner_failed_to_start","message":"The runner for this session is not available — it may have failed to start. See the host logs."},{"id":"user_1","type":"message","response_id":"turn_1","role":"user","content":[{"type":"input_text","text":"Hello"}]}],"has_more":false}"#
    )
    let client = try harness.makeClient()
    _ = try await client.connect()
    let original = try await client.conversationPage(id: "conv_a")
    let reopened = try await client.conversationPage(id: "conv_a")
    XCTAssertEqual(original.snapshot.messages, reopened.snapshot.messages)
    XCTAssertEqual(reopened.snapshot.messages.map(\.id), ["user_1", "error_1"])
    XCTAssertEqual(reopened.snapshot.messages.last?.role, .tool)
    XCTAssertEqual(
      reopened.snapshot.messages.last?.text,
      "Error (runner_failed_to_start): The runner for this session is not available — it may have failed to start. See the host logs."
    )
    XCTAssertEqual(reopened.snapshot.session.status, .idle)
    XCTAssertEqual(
      reopened.snapshot.session.failureMessage,
      "The last response failed. Check the server or provider sign-in.")
    XCTAssertTrue(reopened.snapshot.messages.allSatisfy { !$0.isStreaming })
  }

  func testMalformedPersistedErrorsDoNotHideMissingCauseBehindUnsupportedPreview() async throws {
    let harness = TransportHarness()
    let client = try harness.makeClient()
    _ = try await client.connect()
    for item in [
      #"{"id":"error_1","type":"error","code":"runner_failed_to_start"}"#,
      #"{"id":"error_1","type":"error","message":"Runner unavailable"}"#,
      #"{"id":"error_1","type":"error","code":" ","message":"Runner unavailable"}"#,
      #"{"id":"error_1","type":"error","code":"runner_failed_to_start","message":"\n"}"#,
    ] {
      harness.respond(
        path: "/v1/sessions/conv_a/items", body: "{\"data\":[\(item)],\"has_more\":false}")
      await expect(.malformedResponse) { _ = try await client.historyPage(sessionID: "conv_a") }
    }
  }

  func testWatchLimitFailsExplicitlyInsteadOfSilentlyMissingInboxSessions() async throws {
    let harness = TransportHarness()
    let client = try harness.makeClient()
    _ = try await client.connect()
    await expect(.watchLimitExceeded) {
      try await client.setWatchedSessionIDs((1...501).map { "session_\($0)" })
    }
    XCTAssertEqual(harness.requests.count, 2)
  }

  func testInventoryFollowsLaterPageAndWatchesPendingSessionOutsideVisiblePage() async throws {
    let harness = TransportHarness()
    let firstPageIDs = (1...50).map { "conv_\($0)" }
    let firstPageItems = firstPageIDs.map {
      "{\"id\":\"\($0)\",\"status\":\"idle\",\"created_at\":1,\"permission_level\":4}"
    }.joined(separator: ",")
    // The server may return fewer items than requested; has_more controls traversal.
    harness.respond(
      path: "/v1/sessions",
      body: "{\"data\":[\(firstPageItems)],\"has_more\":true,\"last_id\":\"conv_50\"}")
    harness.respond(
      path: "/v1/sessions", after: "conv_50",
      body:
        #"{"data":[{"id":"conv_later","title":"Unloaded approval","status":"idle","created_at":1,"permission_level":4,"archived":true,"parent_session_id":"conv_1","pending_elicitations_count":1}],"has_more":false}"#
    )
    harness.respond(
      path: "/v1/sessions/conv_later",
      body:
        #"{"id":"conv_later","title":"Unloaded approval","status":"idle","created_at":1,"permission_level":4,"archived":true,"pending_elicitations":[{"elicitation_id":"later_approval","params":{"message":"Approve from the later page?","requestedSchema":{}}}]}"#
    )
    harness.respond(path: "/v1/sessions/conv_later/items", body: #"{"data":[],"has_more":false}"#)
    let client = try harness.makeClient()
    _ = try await client.connect()

    let visiblePage = try await client.sessionPage(limit: 50)
    XCTAssertEqual(visiblePage.sessions.map(\.id), firstPageIDs)
    XCTAssertFalse(visiblePage.sessions.contains { $0.status == .needsResponse })
    let inventory = try await client.sessionInventory()
    XCTAssertEqual(inventory.map(\.id), firstPageIDs + ["conv_later"])
    let pending = inventory.filter { $0.status == .needsResponse }
    XCTAssertEqual(pending.map(\.id), ["conv_later"])
    XCTAssertTrue(try XCTUnwrap(pending.first).isArchived)

    let requests = harness.requests.filter { $0.url?.path == "/v1/sessions" }
    XCTAssertEqual(requests.count, 3)
    let inventoryQueries = try requests.dropFirst().map { queryItems(try XCTUnwrap($0.url)) }
    XCTAssertNil(inventoryQueries[0]["after"])
    XCTAssertEqual(inventoryQueries[1]["after"], "conv_50")
    for query in inventoryQueries {
      XCTAssertEqual(query["limit"], "500")
      XCTAssertEqual(query["kind"], "any")
      XCTAssertEqual(query["include_archived"], "true")
    }

    try await client.setWatchedSessionIDs(inventory.map(\.id))
    let watched = await client.watchedIDs
    XCTAssertEqual(watched, (firstPageIDs + ["conv_later"]).sorted())
    let conversation = try await client.conversationPage(id: pending[0].id)
    XCTAssertEqual(conversation.snapshot.pendingDecisions.map(\.id), ["later_approval"])
    XCTAssertEqual(conversation.snapshot.pendingDecisions.first?.targetSessionID, "conv_later")

    let activities = await client.activityUpdates()
    var iterator = activities.makeAsyncIterator()
    try await client.handleListMessage(
      Data(
        #"{"type":"changed","items":[{"id":"conv_later","status":"idle","created_at":1,"permission_level":4,"archived":true,"pending_elicitations_count":0}]}"#
          .utf8))
    let activity = await iterator.next()
    guard case .sessionsChanged(let changed) = activity else {
      return XCTFail("Expected an update for the watched session outside the visible page")
    }
    XCTAssertEqual(changed.map(\.id), ["conv_later"])
    XCTAssertEqual(changed.first?.status, .idle)
    let invalidation = await iterator.next()
    XCTAssertEqual(invalidation, .inventoryInvalidated)
    let watchedAfterUpdate = await client.watchedIDs
    XCTAssertEqual(watchedAfterUpdate, watched)
  }

  func testOptInLocalServerFixtureSmoke() async throws {
    guard ProcessInfo.processInfo.environment["OMNI_LOCAL_API_TESTS"] == "1" else {
      throw XCTSkip("Set OMNI_LOCAL_API_TESTS=1 after seeding the isolated local server fixtures.")
    }
    // Use the default credential-free transport and read the dedicated fixture only.
    let client = try LocalServerSessionClient(
      baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:6767")))
    let info = try await client.connect()
    XCTAssertEqual(info.userID, "local")
    XCTAssertEqual(info.baseURL.absoluteString, "http://127.0.0.1:6767")

    let first = try await client.sessionPage(limit: 2)
    XCTAssertEqual(first.sessions.count, 2)
    var cursor = first.nextCursor
    var sessions = first.sessions
    var cursors = Set<String>()
    while let after = cursor {
      XCTAssertTrue(cursors.insert(after).inserted)
      let page = try await client.sessionPage(after: after, limit: 2)
      sessions += page.sessions
      cursor = page.nextCursor
    }
    XCTAssertEqual(Set(sessions.map(\.id)).count, sessions.count)
    XCTAssertGreaterThanOrEqual(sessions.count, 3)

    let fixtureID = "f1000000000000000000000000000001"
    let fixture = try XCTUnwrap(sessions.first { $0.id == fixtureID })
    XCTAssertEqual(fixture.title, "Local API validation")
    let latest = try await client.conversationPage(id: fixtureID)
    XCTAssertEqual(latest.snapshot.id, fixtureID)
    XCTAssertFalse(latest.snapshot.session.isReadOnly)
    XCTAssertTrue(latest.snapshot.decisions.isEmpty)
    XCTAssertEqual(latest.snapshot.messages.count, 50)
    XCTAssertEqual(
      latest.snapshot.messages.map(\.text),
      (11...60).map { String(format: "Local API fixture message %02d.", $0) })

    let olderCursor = try XCTUnwrap(latest.nextCursor)
    let older = try await client.historyPage(sessionID: fixtureID, after: olderCursor)
    XCTAssertEqual(older.messages.count, 10)
    XCTAssertNil(older.nextCursor)
    let allMessages = older.messages + latest.snapshot.messages
    XCTAssertEqual(Set(allMessages.map(\.id)).count, 60)
    XCTAssertEqual(
      allMessages.map(\.text),
      (1...60).map { String(format: "Local API fixture message %02d.", $0) })
    XCTAssertTrue(allMessages.allSatisfy { !$0.isStreaming })
  }

  func testHTTPRequiresLiteralLoopbackRoots() throws {
    for address in ["http://127.0.0.1:6767", "http://127.0.0.1:6767/", "http://[::1]:6767"] {
      XCTAssertNoThrow(try LocalServerSessionClient(baseURL: XCTUnwrap(URL(string: address))))
    }
    for address in [
      "http://localhost:6767", "http://192.168.1.2:6767",
      "http://127.0.0.2:6767", "http://example.com", "http://user:secret@127.0.0.1:6767",
      "http://127.0.0.1:6767/api", "http://127.0.0.1:6767?token=secret",
      "http://127.0.0.1:6767#fragment", "http://127.0.0.1:0", "http://127.0.0.1:65536",
    ] {
      XCTAssertThrowsError(try LocalServerSessionClient(baseURL: XCTUnwrap(URL(string: address)))) {
        XCTAssertEqual($0 as? LocalServerClientError, .invalidBaseURL, address)
      }
    }
  }

  func testConnectVerifiesDiscoveryAndIdentityWithoutCredentials() async throws {
    let harness = TransportHarness()
    let client = try harness.makeClient()
    let info = try await client.connect()
    XCTAssertEqual(info.baseURL.absoluteString, "http://127.0.0.1:\(harness.port)")
    XCTAssertEqual(info.userID, "local")
    XCTAssertEqual(harness.requests.map { $0.url!.path }, ["/v1/info", "/v1/me"])
    for request in harness.requests {
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertNil(request.httpBody)
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
      XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
      XCTAssertFalse(request.httpShouldHandleCookies)
    }
  }

  func testReadsRequireSuccessfulConnect() async throws {
    let harness = TransportHarness()
    let client = try harness.makeClient()
    await expect(.notConnected) { _ = try await client.sessions() }
    await expect(.notConnected) { _ = try await client.conversation(id: "conv_a") }
    await expect(.notConnected) { _ = try await client.historyPage(sessionID: "conv_a") }
    XCTAssertTrue(harness.requests.isEmpty)
  }

  func testUnsupportedAuthenticationFailsClosed() async throws {
    for response in [
      #"{"single_user":false,"accounts_enabled":false}"#,
      #"{"single_user":true,"accounts_enabled":true}"#,
    ] {
      let harness = TransportHarness()
      harness.respond(path: "/v1/info", body: response)
      let client = try harness.makeClient()
      await expect(.unsupportedAuthentication) { _ = try await client.connect() }
      await expect(.notConnected) { _ = try await client.sessions() }
      XCTAssertEqual(harness.requests.count, 1)
    }
  }

  func testMissingOrDifferentIdentityFailsClosed() async throws {
    for response in [#"{"user_id":null}"#, "{}", #"{"user_id":"someone-else"}"#] {
      let harness = TransportHarness()
      harness.respond(path: "/v1/me", body: response)
      let client = try harness.makeClient()
      await expect(.identityUnavailable) { _ = try await client.connect() }
      await expect(.notConnected) { _ = try await client.sessions() }
      XCTAssertEqual(harness.requests.count, 2)
    }
  }

  func testSessionPagesPreserveOrderAndReadOnlyMetadata() async throws {
    let harness = TransportHarness()
    harness.respond(
      path: "/v1/sessions",
      body: """
        {"data":[
          {"id":"conv_new","status":"running","created_at":10,"updated_at":30,
           "title":"Newest","agent_name":"Omni","workspace":"/workspace",
           "labels":{"omnigent.pinned":"123"},"permission_level":4},
          {"id":"conv_old","status":"idle","created_at":5,"updated_at":20,
           "title":null,"archived":true,"pending_elicitations_count":1},
          {"id":"conv_old","status":"idle","created_at":5}
        ],"has_more":true,"last_id":"conv_old"}
        """)
    let client = try harness.makeClient()
    _ = try await client.connect()
    let page = try await client.sessionPage(after: "conv_before", limit: 2)
    XCTAssertEqual(page.sessions.map(\.id), ["conv_new", "conv_old"])
    XCTAssertEqual(page.nextCursor, "conv_old")
    XCTAssertFalse(page.sessions[0].isReadOnly)
    XCTAssertTrue(page.sessions[1].isReadOnly)
    XCTAssertTrue(page.sessions[0].isPinned)
    XCTAssertEqual(page.sessions[0].status, .running)
    XCTAssertEqual(page.sessions[0].updatedAt, Date(timeIntervalSince1970: 30))
    XCTAssertEqual(page.sessions[0].workspace, "/workspace")
    XCTAssertTrue(page.sessions[1].isArchived)
    XCTAssertEqual(page.sessions[1].status, .needsResponse)
    XCTAssertEqual(page.sessions[1].title, "Untitled session")
    let query = queryItems(try XCTUnwrap(harness.requests.last?.url))
    XCTAssertEqual(query["order"], "desc")
    XCTAssertEqual(query["sort_by"], "updated_at")
    XCTAssertEqual(query["limit"], "2")
    XCTAssertEqual(query["after"], "conv_before")
    XCTAssertEqual(query["include_archived"], "true")
  }

  func testHistoryPagesUseStoredOrderAndPreserveTypedContent() async throws {
    let harness = TransportHarness()
    harness.respond(
      path: "/v1/sessions/conv_a/items",
      body: """
        {"data":[
          {"id":"msg_z","type":"message","role":"assistant","content":[
            {"type":"output_text","text":"Hello"},{"type":"output_text","text":"World"}]},
          {"id":"msg_a","type":"message","role":"user","content":[
            {"type":"input_text","text":"See picture"},{"type":"input_image","image_url":"ignored"}]},
          {"id":"msg_a","type":"message","role":"user","content":"duplicate"},
          {"id":"tool_1","type":"function_call","name":"read_file","arguments":"file.txt"},
          {"id":"reason_1","type":"reasoning"}
        ],"has_more":true,"last_id":"reason_1"}
        """)
    let client = try harness.makeClient()
    _ = try await client.connect()
    let page = try await client.historyPage(sessionID: "conv_a", after: "cursor +&?", limit: 4)
    XCTAssertEqual(page.messages.map(\.id), ["reason_1", "tool_1", "msg_a", "msg_z"])
    XCTAssertEqual(page.nextCursor, "reason_1")
    XCTAssertEqual(page.messages.last?.text, "Hello\nWorld")
    XCTAssertEqual(page.messages[2].role, .user)
    XCTAssertEqual(page.messages[2].text, "See picture")
    XCTAssertEqual(page.messages[2].attachments?.first?.kind, .image)
    XCTAssertEqual(page.messages[2].attachments?.first?.reference, "ignored")
    XCTAssertEqual(page.messages[1].text, "Tool call: read_file\nfile.txt")
    XCTAssertEqual(page.messages[0].role, .tool)
    XCTAssertEqual(page.messages[0].activity?.kind, .reasoning)
    XCTAssertEqual(page.messages[0].activity?.summary, "No public reasoning summary was provided.")
    XCTAssertTrue(page.messages.allSatisfy { !$0.isStreaming })
    let query = queryItems(try XCTUnwrap(harness.requests.last?.url))
    XCTAssertEqual(query["after"], "cursor +&?")
    XCTAssertEqual(query["order"], "desc")
    XCTAssertEqual(query["limit"], "4")
  }

  func testConversationPageLoadsMetadataAndLatestHistoryWithIncreasingRevisions() async throws {
    let harness = TransportHarness()
    harness.respond(
      path: "/v1/sessions/conv_a",
      body:
        #"{"id":"conv_a","status":"waiting","created_at":10,"pending_elicitations":[{"elicitation_id":"pending_1","params":{"message":"Approve?","requestedSchema":{}}}]}"#
    )
    harness.respond(
      path: "/v1/sessions/conv_a/items",
      body:
        #"{"data":[{"id":"msg_1","type":"message","role":"assistant","content":"Ready"}],"last_id":"msg_1","has_more":true}"#
    )
    let client = try harness.makeClient()
    _ = try await client.connect()
    let first = try await client.conversationPage(id: "conv_a", limit: 1)
    let second = try await client.conversation(id: "conv_a")
    XCTAssertEqual(first.nextCursor, "msg_1")
    XCTAssertEqual(first.snapshot.messages.map(\.text), ["Ready"])
    XCTAssertEqual(first.snapshot.session.status, .needsResponse)
    XCTAssertTrue(first.snapshot.session.isReadOnly)
    XCTAssertEqual(first.snapshot.decisions.map(\.id), ["pending_1"])
    XCTAssertGreaterThan(second.revision, first.snapshot.revision)
    let snapshotRequest = try XCTUnwrap(
      harness.requests.first { $0.url?.path == "/v1/sessions/conv_a" })
    XCTAssertEqual(queryItems(try XCTUnwrap(snapshotRequest.url))["include_items"], "false")
    _ = await client.updates()
  }

  func testEmptyHistoryAndToolOutputs() async throws {
    let harness = TransportHarness()
    harness.respond(path: "/v1/sessions/conv_a/items", body: #"{"data":[],"has_more":false}"#)
    let client = try harness.makeClient()
    _ = try await client.connect()
    let empty = try await client.historyPage(sessionID: "conv_a")
    XCTAssertEqual(empty.messages, [])
    XCTAssertNil(empty.nextCursor)
    harness.respond(
      path: "/v1/sessions/conv_a/items",
      body:
        #"{"data":[{"id":"out_1","type":"function_call_output","output":[{"type":"text","text":"Result"}]}],"has_more":false}"#
    )
    let output = try await client.historyPage(sessionID: "conv_a")
    XCTAssertEqual(output.messages.first?.text, "Result")
    XCTAssertEqual(output.messages.first?.role, .tool)
  }

  func testHiddenMetaMessagesDoNotLeakAndAnAllMetaPageKeepsItsCursor() async throws {
    let harness = TransportHarness()
    harness.respond(
      path: "/v1/sessions/conv_a/items",
      body:
        #"{"data":[{"id":"meta_1","type":"message","role":"user","is_meta":true,"content":[{"type":"input_text","text":"Hidden harness context"}]}],"has_more":true,"last_id":"meta_1"}"#
    )
    let client = try harness.makeClient()
    _ = try await client.connect()
    let hiddenPage = try await client.historyPage(sessionID: "conv_a")
    XCTAssertTrue(hiddenPage.messages.isEmpty)
    XCTAssertEqual(hiddenPage.nextCursor, "meta_1")
    harness.respond(
      path: "/v1/sessions/conv_a/items",
      body:
        #"{"data":[{"id":"msg_1","type":"message","role":"user","is_meta":false,"content":"Visible user text"}],"has_more":false,"last_id":"msg_1"}"#
    )
    let visiblePage = try await client.historyPage(
      sessionID: "conv_a", after: hiddenPage.nextCursor)
    XCTAssertEqual(visiblePage.messages.map(\.text), ["Visible user text"])
    XCTAssertNil(visiblePage.nextCursor)
  }

  func testInvalidAndRepeatedPaginationCursorsFail() async throws {
    for response in [
      #"{"data":[],"has_more":true}"#,
      #"{"data":[],"has_more":true,"last_id":""}"#,
      #"{"data":[],"has_more":true,"last_id":"same"}"#,
    ] {
      let harness = TransportHarness()
      harness.respond(path: "/v1/sessions", body: response)
      let client = try harness.makeClient()
      _ = try await client.connect()
      await expect(.invalidPagination) { _ = try await client.sessionPage(after: "same") }
    }
  }

  func testMalformedResponsesAndHistoryAreNotReportedAsEmptySuccess() async throws {
    for response in ["not json", "{}", #"{"single_user":"true","accounts_enabled":false}"#] {
      let harness = TransportHarness()
      harness.respond(path: "/v1/info", body: response)
      let client = try harness.makeClient()
      await expect(.malformedResponse) { _ = try await client.connect() }
    }
    let harness = TransportHarness()
    let client = try harness.makeClient()
    _ = try await client.connect()
    for item in [
      #"{"id":"m","type":"message","content":"missing role"}"#,
      #"{"id":"m","type":"message","role":"assistant","content":123}"#,
      #"{"id":"m","type":"message","role":"assistant","content":[{"type":"output_text"}]}"#,
      #"{"id":"","type":"message","role":"assistant","content":"empty id"}"#,
    ] {
      harness.respond(
        path: "/v1/sessions/conv_a/items", body: "{\"data\":[\(item)],\"has_more\":false}")
      await expect(.malformedResponse) { _ = try await client.historyPage(sessionID: "conv_a") }
    }
  }

  func testStatusFailuresAndRedirectResponsesAreExplicit() async throws {
    let cases: [(Int, LocalServerClientError)] = [
      (301, .redirectNotAllowed), (302, .redirectNotAllowed), (401, .unauthorized),
      (403, .forbidden), (404, .httpStatus(404)), (500, .httpStatus(500)), (204, .httpStatus(204)),
    ]
    for (status, expected) in cases {
      let harness = TransportHarness()
      harness.respond(path: "/v1/info", body: "{}", status: status)
      let client = try harness.makeClient()
      await expect(expected) { _ = try await client.connect() }
      XCTAssertEqual(harness.requests.count, 1)
    }
  }

  func testResponseFromDifferentURLIsRejected() async throws {
    let harness = TransportHarness()
    harness.respond(
      path: "/v1/info", body: #"{"single_user":true,"accounts_enabled":false}"#,
      responseURL: URL(string: "http://example.com/v1/info"))
    let client = try harness.makeClient()
    await expect(.redirectNotAllowed) { _ = try await client.connect() }
    XCTAssertEqual(harness.requests.count, 1)
  }

  func testTransportFailureAndCancellationAreDistinct() async throws {
    let harness = TransportHarness()
    harness.fail(path: "/v1/info", code: .cannotConnectToHost)
    let client = try harness.makeClient()
    await expect(.transport(URLError.cannotConnectToHost.rawValue)) {
      _ = try await client.connect()
    }
    for code: URLError.Code in [.userAuthenticationRequired, .userCancelledAuthentication] {
      harness.fail(path: "/v1/info", code: code)
      await expect(.unauthorized) { _ = try await client.connect() }
    }
    harness.fail(path: "/v1/info", code: .cancelled)
    do {
      _ = try await client.connect()
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }

  func testAuthenticationLossRevokesReadAccessUntilReconnected() async throws {
    let harness = TransportHarness()
    let client = try harness.makeClient()
    _ = try await client.connect()
    harness.respond(path: "/v1/sessions", body: "{}", status: 401)
    await expect(.unauthorized) { _ = try await client.sessions() }
    await expect(.notConnected) { _ = try await client.sessions() }
    XCTAssertEqual(harness.requests.count, 3)
  }

  func testInvalidIdentifiersAndLimitsNeverMakeResourceRequests() async throws {
    let harness = TransportHarness()
    let client = try harness.makeClient()
    _ = try await client.connect()
    for id in ["", "../info", "a/b", "a?token=x", "a#fragment"] {
      await expect(.invalidIdentifier) { _ = try await client.conversation(id: id) }
    }
    for limit in [0, -1, 1001] {
      await expect(.invalidPageLimit) { _ = try await client.sessionPage(limit: limit) }
      await expect(.invalidPageLimit) {
        _ = try await client.historyPage(sessionID: "conv_a", limit: limit)
      }
      await expect(.invalidPageLimit) {
        _ = try await client.conversationPage(id: "conv_a", limit: limit)
      }
    }
    await expect(.invalidPagination) { _ = try await client.sessionPage(after: "") }
    XCTAssertEqual(harness.requests.count, 2)
  }

  func testReadOnlyPermissionPreventsMutationRequests() async throws {
    let harness = TransportHarness()
    harness.respond(
      path: "/v1/sessions/conv_a",
      body: #"{"id":"conv_a","status":"idle","created_at":1,"permission_level":1}"#)
    let client = try harness.makeClient()
    _ = try await client.connect()
    let actions: [() async throws -> Void] = [
      { try await client.send("Hello", to: "conv_a") },
      { try await client.interrupt(sessionID: "conv_a") },
      { try await client.resolve(decisionID: "d", sessionID: "conv_a", response: .approve) },
      { try await client.editSession("conv_a", change: .title("Changed")) },
      { try await client.editSession("conv_a", change: .archived(true)) },
    ]
    for action in actions {
      do {
        try await action()
        XCTFail("Expected read-only rejection")
      } catch {
        XCTAssertEqual(error as? SessionClientError, .readOnly)
      }
    }
    XCTAssertTrue(harness.requests.allSatisfy { $0.httpMethod == "GET" })
    await expect(.creationRequiresHost) { _ = try await client.createSession(title: "New") }
  }

  private func queryItems(_ url: URL) -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        ?? [])
        .compactMap { item in item.value.map { (item.name, $0) } })
  }

  private func expect(
    _ expected: LocalServerClientError, file: StaticString = #filePath, line: UInt = #line,
    action: () async throws -> Void
  ) async {
    do {
      try await action()
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? LocalServerClientError, expected, file: file, line: line)
    }
  }
}

final class TransportHarness: @unchecked Sendable {
  struct Stub {
    var body: String
    var status = 200
    var responseURL: URL?
    var errorCode: URLError.Code?
    var delay: TimeInterval = 0
  }

  let port: Int
  private let lock = NSLock()
  private var recorded: [URLRequest] = []
  private var requestObserver: ((URLRequest) -> Void)?
  private var queuedStubs: [String: [Stub]] = [:]
  private var stubs: [String: Stub] = [
    "/v1/info": Stub(body: #"{"single_user":true,"accounts_enabled":false}"#),
    "/v1/me": Stub(body: #"{"user_id":"local","is_admin":true}"#),
  ]

  init() {
    port = StubURLProtocol.register()
    StubURLProtocol.attach(self, port: port)
  }

  deinit {
    StubURLProtocol.remove(port: port)
  }

  var requests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    configuration.httpAdditionalHeaders = [
      "Authorization": "must-not-be-sent", "Cookie": "must-not-be-sent",
    ]
    return URLSession(configuration: configuration)
  }

  func makeClient(baseURL: URL? = nil, bearerToken: String? = nil, expectedUserID: String? = nil)
    throws -> LocalServerSessionClient
  {
    let session = makeSession()
    defer { session.invalidateAndCancel() }
    return try LocalServerSessionClient(
      baseURL: baseURL ?? URL(string: "http://127.0.0.1:\(port)")!, bearerToken: bearerToken,
      expectedUserID: expectedUserID, session: session)
  }

  func respond(
    path: String, after: String? = nil, body: String, status: Int = 200, responseURL: URL? = nil,
    method: String? = nil
  ) {
    lock.lock()
    defer { lock.unlock() }
    let base = after.map { "\(path)?after=\($0)" } ?? path
    let key = method.map { "\($0) \(base)" } ?? base
    stubs[key] = Stub(body: body, status: status, responseURL: responseURL)
  }

  func enqueue(path: String, method: String, stubs: [Stub]) {
    lock.lock()
    defer { lock.unlock() }
    queuedStubs["\(method) \(path)"] = stubs
  }

  func fail(path: String, code: URLError.Code) {
    lock.lock()
    defer { lock.unlock() }
    stubs[path] = Stub(body: "", errorCode: code)
  }

  func writableSession(pending: String = "[]") {
    respond(
      path: "/v1/sessions/conv_a",
      body:
        "{\"id\":\"conv_a\",\"status\":\"idle\",\"created_at\":1,\"permission_level\":4,\"pending_elicitations\":\(pending)}"
    )
    respond(path: "/v1/sessions/conv_a/items", body: #"{"data":[],"has_more":false}"#)
  }

  func observeRequests(_ observer: @escaping (URLRequest) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    requestObserver = observer
  }

  func response(for request: URLRequest) -> Stub {
    lock.lock()
    defer { lock.unlock() }
    var captured = request
    if captured.httpBody == nil, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4_096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
      }
      captured.httpBody = data
    }
    recorded.append(captured)
    requestObserver?(captured)
    let path = request.url?.path ?? ""
    let methodPath = "\(request.httpMethod ?? "GET") \(path)"
    if var queued = queuedStubs[methodPath], !queued.isEmpty {
      let first = queued.removeFirst()
      queuedStubs[methodPath] = queued
      return first
    }
    let after = request.url.flatMap {
      URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "after" }?.value
    }
    if let after, let stub = stubs["\(path)?after=\(after)"] { return stub }
    if let stub = stubs[methodPath] { return stub }
    return stubs[path] ?? Stub(body: "{}", status: 404)
  }
}

extension LocalServerSessionClient {
  func primeEventReducerForTesting(_ id: String) {
    watchedSessionID = id
    reducer = LiveConversationReducer(
      snapshot: ConversationSnapshot(
        revision: 1,
        session: SessionSummary(id: id, title: "Event fixture", preview: ""), messages: []))
  }

  func primeStreamForTesting(_ id: String) {
    watchedSessionID = id
    streamReady = true
  }

  fileprivate func failHydrationForTesting(_ error: LocalServerClientError) {
    hydrationFailed(error, sessionID: watchedSessionID!, generation: streamGeneration)
  }
}

private final class WeakHarness {
  weak var value: TransportHarness?

  init(_ value: TransportHarness) { self.value = value }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  private static let registryLock = NSLock()
  private static var nextPort = 20_000
  private static var registry: [Int: WeakHarness] = [:]

  static func register() -> Int {
    registryLock.lock()
    defer { registryLock.unlock() }
    nextPort += 1
    return nextPort
  }

  static func attach(_ harness: TransportHarness, port: Int) {
    registryLock.lock()
    defer { registryLock.unlock() }
    registry[port] = WeakHarness(harness)
  }

  static func remove(port: Int) {
    registryLock.lock()
    defer { registryLock.unlock() }
    registry.removeValue(forKey: port)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.registryLock.lock()
    let harness = Self.registry[request.url?.port ?? 0]?.value
    Self.registryLock.unlock()
    guard let harness else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    let stub = harness.response(for: request)
    if stub.delay > 0 { Thread.sleep(forTimeInterval: stub.delay) }
    if let code = stub.errorCode {
      client?.urlProtocol(self, didFailWithError: URLError(code))
      return
    }
    let response = HTTPURLResponse(
      url: stub.responseURL ?? request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
