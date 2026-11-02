import AppKit
import Foundation
import OWLProtocol
import OmnigentInput
import Testing

@testable import OmnigentWebLayer

@Suite("Wire format")
struct WireTests {
  @Test func roundTripsEveryFieldType() throws {
    let encoded = WireEncoder()
      .u64(.width, 42)
      .i64(.errorCode, -3)
      .double(.scale, 2.5)
      .bool(.visible, true)
      .string(.URL, "https://example.com/é")
      .bytes(.PNG, [0, 1, 2, 255])
    let decoded = try WireDecoder(encoded.bytes)
    #expect(decoded.u64(.width) == 42)
    #expect(decoded.i64(.errorCode) == -3)
    #expect(decoded.double(.scale) == 2.5)
    #expect(decoded.bool(.visible))
    #expect(decoded.bool(.focused, missing: true))
    #expect(decoded.string(.URL) == "https://example.com/é")
    #expect(decoded.data(.PNG) == Data([0, 1, 2, 255]))
  }

  @Test func layoutMatchesTheSchema() {
    // tag 21 (URL) little-endian, type 5 (string), reserved, length 2, then "ab".
    #expect(WireEncoder().string(.URL, "ab").bytes == [21, 0, 5, 0, 2, 0, 0, 0, 97, 98])
  }

  @Test func wrongTypesAndMissingFieldsReadAsNil() throws {
    let decoded = try WireDecoder(WireEncoder().string(.width, "not a number").bytes)
    #expect(decoded.u64(.width) == nil)
    #expect(decoded.string(.title) == nil)
    #expect(throws: WebLayerError.self) {
      try decoded.require(decoded.u64(.width), .width, in: .viewResize)
    }
  }

  @Test func unknownTagsAreSkipped() throws {
    var bytes = WireEncoder().u64(.width, 7).bytes
    bytes += [0xFF, 0x7F, 1, 0, 8, 0, 0, 0] + [UInt8](repeating: 9, count: 8)
    bytes += WireEncoder().u64(.height, 8).bytes
    let decoded = try WireDecoder(bytes)
    #expect(decoded.u64(.width) == 7)
    #expect(decoded.u64(.height) == 8)
  }

  @Test func truncatedPayloadsAreErrors() {
    let bytes = WireEncoder().string(.URL, "abcdef").bytes
    #expect(throws: WebLayerError.self) { try WireDecoder(Array(bytes.dropLast())) }
    #expect(throws: WebLayerError.self) { try WireDecoder([1, 0, 1]) }
  }
}

@Suite("DevTools results")
struct DevToolsResultTests {
  @Test func evaluateResults() throws {
    #expect(
      try WebScriptValue.fromEvaluateResult(json: #"{"result":{"type":"number","value":2}}"#)
        == .number(2))
    #expect(
      try WebScriptValue.fromEvaluateResult(json: #"{"result":{"type":"undefined"}}"#)
        == .undefined)
    #expect(
      try WebScriptValue.fromEvaluateResult(
        json: #"{"result":{"type":"object","value":{"a":[true,null,"x"]}}}"#)
        == .object(["a": .array([.bool(true), .null, .string("x")])]))
    let nan = try WebScriptValue.fromEvaluateResult(
      json: #"{"result":{"type":"number","unserializableValue":"NaN"}}"#)
    guard case .number(let value) = nan else {
      Issue.record("expected a number")
      return
    }
    #expect(value.isNaN)
  }

  @Test func exceptionsAreScriptFailures() {
    let json = #"""
      {"result":{"type":"object"},"exceptionDetails":{"text":"Uncaught",
       "exception":{"description":"Error: boom"}}}
      """#
    #expect(throws: WebLayerError.scriptFailed("Error: boom")) {
      try WebScriptValue.fromEvaluateResult(json: json)
    }
  }

  @Test func garbageIsReported() {
    #expect(throws: WebLayerError.self) { try WebScriptValue.fromEvaluateResult(json: "nope") }
    #expect(DevToolsJSON.failureMessage(#"{"message":"no target"}"#) == "no target")
    #expect(DevToolsJSON.failureMessage("plain text") == "plain text")
  }
}

@MainActor
@Suite("Agent and unhandled keys")
struct InputTranslationTests {
  @Test func agentKeysPressAndRelease() {
    #expect(AgentKey.enter.keyInputs(modifiers: []).map(\.kind) == [.rawKeyDown, .char, .keyUp])
    #expect(AgentKey.arrowLeft.keyInputs(modifiers: []).map(\.kind) == [.rawKeyDown, .keyUp])
    #expect(AgentKey.character("k").nativeKeyCode == 40)
  }

  @Test func unhandledKeysAreRebuiltAsKeyDown() throws {
    let event = try #require(
      InputTranslator.unhandledKeyEvent(
        UnhandledKey(
          keyCode: 32, modifiers: [.command, .shift], character: 85, unmodifiedCharacter: 117),
        template: nil, windowNumber: 0))
    #expect(event.type == .keyDown)
    #expect(event.keyCode == 32)
    #expect(event.modifierFlags.contains([.command, .shift]))
    #expect(event.charactersIgnoringModifiers == "u")
  }
}

@MainActor
@Suite("Channel")
struct ChannelTests {
  @Test func deliversMessagesAndPortsFromTheHostSide() async throws {
    let name = "ai.omnigent.owl.test.\(getpid()).\(UUID().uuidString.prefix(8))"
    let client = try HostChannel.listen(serviceName: name)
    var received: [IncomingMessage] = []
    client.onEvent = { event in
      if case .message(let message) = event { received.append(message) }
    }
    client.start()
    var host: OpaquePointer?
    #expect(unsafe owl_channel_connect(name, &host) == KERN_SUCCESS)
    let hostChannel = unsafe try #require(host)
    let payload = WireEncoder().string(.token, "secret").bytes
    let large = WireEncoder().bytes(.PNG, [UInt8](repeating: 7, count: 20_000)).bytes
    for bytes in [payload, large] {
      let result = bytes.withUnsafeBytes { buffer in
        unsafe owl_channel_send(
          hostChannel, OWLMessageKind.hello.rawValue, 5, 9, buffer.baseAddress, buffer.count,
          owl_channel_receive_port(hostChannel), mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND),
          100)
      }
      #expect(result == KERN_SUCCESS)
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while received.count < 2, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(received.count == 2)
    #expect(received.first?.kind == .hello)
    #expect(received.first?.request == 5)
    #expect(received.first?.target == 9)
    #expect(received.first?.fields.string(.token) == "secret")
    #expect(received.first?.port != nil)
    #expect(received.last?.fields.data(.PNG)?.count == 20_000)
    if let port = received.first?.port {
      try client.adoptPeer(port)
      try client.send(.helloAck, WireEncoder().bool(.accepted, true))
    }
    client.invalidate()
    unsafe owl_channel_destroy(hostChannel)
  }

  @Test func rejectsMessagesFromUnexpectedProcesses() async throws {
    let name = "ai.omnigent.owl.test.\(getpid()).\(UUID().uuidString.prefix(8))"
    let client = try HostChannel.listen(serviceName: name)
    var failures: [WebLayerError] = []
    var messages = 0
    client.onEvent = { event in
      switch event {
      case .message: messages += 1
      case .failure(let error): failures.append(error)
      case .peerDied: break
      }
    }
    client.expect(pid: getpid() + 1)
    client.start()
    var host: OpaquePointer?
    #expect(unsafe owl_channel_connect(name, &host) == KERN_SUCCESS)
    let hostChannel = unsafe try #require(host)
    _ = unsafe owl_channel_send(
      hostChannel, OWLMessageKind.hello.rawValue, 0, 0, nil, 0, mach_port_t(MACH_PORT_NULL),
      mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND), 100)
    try await Task.sleep(for: .milliseconds(200))
    #expect(messages == 0)
    #expect(failures.count == 1)
    client.invalidate()
    unsafe owl_channel_destroy(hostChannel)
  }
}

@MainActor
@Suite("Session")
struct SessionTests {
  @Test func missingHostFailsWithATypedError() {
    let session = Session(
      configuration: SessionConfiguration(
        hostAppURL: URL(fileURLWithPath: "/nonexistent/Omnigent Web Host.app"),
        rootCacheURL: FileManager.default.temporaryDirectory))
    let profile = session.profile(identifier: "server:a", persistence: .persistent)
    let view = profile.makeWebView(initialURL: URL(string: "https://example.com"))
    session.start()
    guard case .failed(.hostNotBundled(let path)) = session.state else {
      Issue.record("expected hostNotBundled, got \(session.state)")
      return
    }
    #expect(path.hasSuffix("Omnigent Web Host.app"))
    #expect(view.status == .waitingForHost)
  }

  @Test func profilesAreCachedByIdentityAndEphemeralOnesAreUnique() {
    let session = Session(
      configuration: SessionConfiguration(
        hostAppURL: URL(fileURLWithPath: "/nonexistent"),
        rootCacheURL: FileManager.default.temporaryDirectory))
    let first = session.profile(identifier: "server:a", persistence: .persistent)
    #expect(session.profile(identifier: "server:a", persistence: .persistent) === first)
    #expect(session.profile(identifier: "server:a", persistence: .ephemeral) !== first)
    let agentA = session.makeEphemeralProfile()
    let agentB = session.makeEphemeralProfile()
    #expect(agentA !== agentB)
    #expect(first.storageKey.count == 32)
  }

  @Test func requestsBeforeReadyThrowNotReady() async {
    let session = Session(
      configuration: SessionConfiguration(
        hostAppURL: URL(fileURLWithPath: "/nonexistent"),
        rootCacheURL: FileManager.default.temporaryDirectory))
    let view = session.profile(identifier: "x", persistence: .ephemeral).makeWebView()
    await #expect(throws: WebLayerError.notReady) { try await view.evaluateJavaScript("1") }
    #expect(throws: WebLayerError.notReady) { try view.renderer.agentType("a") }
  }
}
