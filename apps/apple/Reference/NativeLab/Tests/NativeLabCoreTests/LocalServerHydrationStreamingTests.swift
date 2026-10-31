import Foundation
import XCTest

@testable import NativeLabCore

final class LocalServerHydrationStreamingTests: XCTestCase {
  func testInitialHydrationPublishesUnindexedDeltasBeforeHistoryAndAppliesThemOnce() async throws {
    let harness = TransportHarness()
    let client = try await makeClient(harness)
    let updates = await client.updates()
    var snapshots = updates.makeAsyncIterator()
    let hydration = await beginSlowHydration(client, harness: harness, history: history())

    try await send(client, #"{"type":"response.output_text.delta","delta":"Hello"}"#)
    try await send(client, #"{"type":"response.output_text.delta","delta":" world"}"#)
    let hydrating = await client.isHydrating
    let ready = await client.streamReady
    XCTAssertTrue(hydrating)
    XCTAssertFalse(ready)
    let first = await snapshots.next()
    let second = await snapshots.next()
    XCTAssertEqual(first?.messages.map(\.text), ["Hello"])
    XCTAssertEqual(second?.messages.map(\.text), ["Hello world"])

    await hydration?.value
    let final = try await snapshot(client)
    XCTAssertEqual(final.messages.map(\.text), ["Question", "Hello world"])
    XCTAssertEqual(final.session.permissionLevel, 4)
    XCTAssertFalse(final.session.isReadOnly)
    let live = await client.streamReady
    XCTAssertTrue(live)
    await client.stopWatching()
  }

  func testRehydrationKeepsGrowingTextAndChunkIndicesWithoutReplayingDeltas() async throws {
    let harness = TransportHarness()
    let client = try await makeClient(harness, seedHistory: true)
    try await send(
      client,
      #"{"type":"response.output_text.delta","message_id":"native","index":0,"delta":"Hello"}"#)
    let hydration = await beginSlowHydration(client, harness: harness, history: history())
    try await send(
      client,
      #"{"type":"response.output_text.delta","message_id":"native","index":1,"delta":" world"}"#)
    let during = try await snapshot(client)
    XCTAssertEqual(during.messages.last?.text, "Hello world")
    await hydration?.value
    try await send(
      client,
      #"{"type":"response.output_text.delta","message_id":"native","index":1,"delta":" world"}"#)
    try await send(
      client, #"{"type":"response.output_text.delta","message_id":"native","index":2,"delta":"!"}"#)
    let final = try await snapshot(client)
    XCTAssertEqual(final.messages.map(\.text), ["Question", "Hello world!"])
    await client.stopWatching()
  }

  func testShorterPersistedPrefixCannotReplaceTextThatGrewDuringHydration() async throws {
    let harness = TransportHarness()
    let client = try await makeClient(harness, seedHistory: true)
    try await send(
      client,
      #"{"type":"response.output_text.delta","message_id":"native","index":0,"delta":"Hello"}"#)
    let hydration = await beginSlowHydration(
      client, harness: harness,
      history: history(
        assistant: #"{"id":"saved","type":"message","role":"assistant","content":"Hello"}"#))
    try await send(
      client,
      #"{"type":"response.output_text.delta","message_id":"native","index":1,"delta":" world"}"#)
    await hydration?.value
    var final = try await snapshot(client)
    XCTAssertEqual(final.messages.map(\.text), ["Question", "Hello world"])
    XCTAssertTrue(try XCTUnwrap(final.messages.last).isStreaming)
    try await send(
      client, #"{"type":"response.output_text.delta","message_id":"native","index":2,"delta":"!"}"#)
    final = try await snapshot(client)
    XCTAssertEqual(final.messages.last?.text, "Hello world!")
    await client.stopWatching()
  }

  func testHydratedCommitReplacesLivePreviewWithoutDuplicatingText() async throws {
    let harness = TransportHarness()
    let client = try await makeClient(harness)
    let hydration = await beginSlowHydration(
      client, harness: harness,
      history: history(
        assistant: #"{"id":"saved","type":"message","role":"assistant","content":"Hello world"}"#))
    try await send(
      client,
      #"{"type":"response.output_text.delta","message_id":"native","index":0,"delta":"Hello"}"#)
    try await send(
      client,
      #"{"type":"response.output_text.delta","message_id":"native","index":1,"delta":" world"}"#)
    await hydration?.value
    try await send(
      client,
      #"{"type":"response.output_text.delta","message_id":"native","index":2,"delta":"late replay"}"#
    )
    let final = try await snapshot(client)
    XCTAssertEqual(final.messages.map(\.id), ["question", "saved"])
    XCTAssertEqual(final.messages.last?.text, "Hello world")
    await client.stopWatching()
  }

  func testConsumedInputIsPublishedImmediatelyAndItsEffectIsNotRepeatedOnHydration() async throws {
    let harness = TransportHarness()
    let client = try await makeClient(harness, seedHistory: true)
    let hydration = await beginSlowHydration(client, harness: harness, history: history())
    let activities = await client.activityUpdates()
    var events = activities.makeAsyncIterator()
    try await send(
      client,
      #"{"type":"session.input.consumed","data":{"item_id":"next","cleared_pending_id":"pending","type":"message","data":{"role":"user","content":"Next question"}}}"#
    )
    let first = await events.next()
    XCTAssertEqual(first, .inputConsumed(sessionID: "conv_a", itemID: "next", pendingID: "pending"))
    let during = try await snapshot(client)
    XCTAssertEqual(during.messages.last?.text, "Next question")
    await hydration?.value
    let next = await events.next()
    XCTAssertEqual(
      next, .historyCursor(sessionID: "conv_a", nextCursor: nil, firstMessageID: "question"))
    let final = try await snapshot(client)
    XCTAssertEqual(final.messages.map(\.id), ["question", "next"])
    await client.stopWatching()
  }

  func testStoppedGenerationCannotPublishLateHydrationOrEvents() async throws {
    let harness = TransportHarness()
    let client = try await makeClient(harness, seedHistory: true)
    let generation = await client.streamGeneration
    let before = try await snapshot(client)
    let hydration = await beginSlowHydration(client, harness: harness, history: history())
    await client.stopWatching()
    try await client.finishHydration(
      LocalConversationPage(snapshot: before, nextCursor: nil), generation: generation)
    try await send(client, #"{"type":"response.output_text.delta","delta":"late"}"#)
    await hydration?.value
    let reducer = await client.reducer
    XCTAssertNil(reducer)
  }

  private func makeClient(_ harness: TransportHarness, seedHistory: Bool = false) async throws
    -> LocalServerSessionClient
  {
    harness.writableSession()
    harness.respond(path: "/v1/sessions/conv_a/items", body: history())
    let client = try harness.makeClient()
    _ = try await client.connect()
    let initial = seedHistory ? try await client.conversation(id: "conv_a") : nil
    await client.prepareHydrationStreamingTest(initial)
    return client
  }

  private func beginSlowHydration(
    _ client: LocalServerSessionClient, harness: TransportHarness, history: String
  ) async -> Task<Void, Never>? {
    let requested = expectation(description: "History request is pending")
    harness.enqueue(
      path: "/v1/sessions/conv_a/items", method: "GET",
      stubs: [.init(body: history, delay: 0.4)])
    harness.observeRequests { request in
      if request.url?.path == "/v1/sessions/conv_a/items" { requested.fulfill() }
    }
    await client.rehydrateAfterMutation(sessionID: "conv_a")
    await fulfillment(of: [requested], timeout: 2)
    return await client.hydrationTask
  }

  private func send(_ client: LocalServerSessionClient, _ json: String) async throws {
    let event = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)).object)
    try await client.handleConversationEvent(event, sessionID: "conv_a")
  }

  private func snapshot(_ client: LocalServerSessionClient) async throws -> ConversationSnapshot {
    let snapshot = await client.reducer?.snapshot
    return try XCTUnwrap(snapshot)
  }

  private func history(assistant: String? = nil) -> String {
    let question = #"{"id":"question","type":"message","role":"user","content":"Question"}"#
    let items = [assistant, question].compactMap { $0 }.joined(separator: ",")
    return "{\"data\":[\(items)],\"has_more\":false}"
  }
}

extension LocalServerSessionClient {
  fileprivate func prepareHydrationStreamingTest(_ initial: ConversationSnapshot?) {
    watchedSessionID = "conv_a"
    reducer = initial.map(LiveConversationReducer.init(snapshot:))
    streamDataTask = session.dataTask(with: baseURL.appending(path: "/test-suspended-stream"))
    receivedHeartbeat = true
  }
}
