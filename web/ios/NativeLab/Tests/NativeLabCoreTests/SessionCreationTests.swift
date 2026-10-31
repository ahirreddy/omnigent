import Foundation
import XCTest

@testable import NativeLabCore

final class SessionCreationTests: XCTestCase {
  private var selection: SessionCreationSelection {
    SessionCreationSelection(hostID: "host_a", agentID: "ag_codex", workspace: "/work/project")
  }

  func testOnlyExplicitReadinessAllowsCreation() throws {
    let agent = CreationAgent(id: "ag_codex", name: "Custom Codex", harness: "codex-native")
    for readiness in [CreationReadiness.notReady, .unknown, .needsAuthentication] {
      let host = CreationHost(
        hostID: "host_a", name: "Mac", status: "online",
        configuredHarnesses: ["codex-native": readiness])
      let catalog = SessionCreationCatalog(hosts: [host], agents: [agent])
      XCTAssertThrowsError(try catalog.validate(selection))
      if readiness == .needsAuthentication {
        XCTAssertTrue(
          catalog.unavailableReason(agentID: agent.id, hostID: host.id)!.contains("Sign in"))
      }
    }
    XCTAssertNoThrow(try catalog().validate(selection))
  }

  func testOfflineManagedUnknownHarnessAndMissingReadinessAreUnavailable() throws {
    for host in [
      CreationHost(
        hostID: "host_a", name: "Mac", status: "offline",
        configuredHarnesses: ["codex-native": .ready]),
      CreationHost(
        hostID: "host_a", name: "Sandbox", status: "online", sandboxProvider: "modal",
        configuredHarnesses: ["codex-native": .ready]),
      CreationHost(hostID: "host_a", name: "Mac", status: "online"),
    ] {
      XCTAssertThrowsError(
        try SessionCreationCatalog(hosts: [host], agents: catalog().agents).validate(selection))
    }
    let unknown = CreationAgent(id: "ag_codex", name: "codex-native-ui", harness: nil)
    XCTAssertThrowsError(
      try SessionCreationCatalog(hosts: catalog().hosts, agents: [unknown]).validate(selection))
    let future = CreationAgent(id: "ag_codex", name: "Future", harness: "future-native")
    XCTAssertFalse(future.supportsCreation)
  }

  func testWorkspaceAndModelAreValidatedWithoutGuessing() throws {
    for path in ["", "~/project", "relative", "/work\0project"] {
      var value = selection
      value.workspace = path
      XCTAssertThrowsError(try catalog().validate(value))
    }
    var value = selection
    value.model = "wire-value"
    XCTAssertThrowsError(try catalog().validate(value))
    XCTAssertThrowsError(
      try catalog().validate(
        value, models: [ModelChoice(id: "id", model: "wire-value", hidden: true)]))
    XCTAssertNoThrow(
      try catalog().validate(value, models: [ModelChoice(id: "id", model: "wire-value")]))
    value.model = "id"
    XCTAssertThrowsError(
      try catalog().validate(value, models: [ModelChoice(id: "id", model: "wire-value")]))
  }

  func testCanonicalNativeAliasesPreserveWrapperContract() throws {
    for (harness, wrapper) in [
      ("claude-native", "claude-code-native-ui"), ("codex-native", "codex-native-ui"),
      ("native-pi", "pi-native-ui"), ("native-cursor", "cursor-native-ui"),
      ("native-kiro", "kiro-native-ui"), ("native-opencode", "opencode-native-ui"),
    ] {
      XCTAssertEqual(CreationAgent(id: "a", name: "custom", harness: harness).wrapper, wrapper)
    }
  }

  func testCatalogPaginatesAndDeduplicatesDurableAgentIDs() async throws {
    let harness = stub()
    harness.respond(
      path: "/v1/agents",
      body:
        #"{"data":[{"id":"ag_first","name":"First","harness":"claude-native"}],"has_more":true,"last_id":"ag_first"}"#
    )
    harness.respond(
      path: "/v1/agents", after: "ag_first",
      body:
        #"{"data":[{"id":"ag_first","name":"First","harness":"claude-native"},{"id":"ag_codex","name":"Second","harness":"codex-native"}],"has_more":false}"#
    )
    let client = try await connected(harness)
    let value = try await client.sessionCreationCatalog()
    XCTAssertEqual(value.agents.map(\.id), ["ag_first", "ag_codex"])
    XCTAssertTrue(harness.requests.allSatisfy { $0.httpMethod == "GET" })
  }

  func testDirectoryPaginationUsesPathAndDoesNotOfferFiles() async throws {
    let harness = stub()
    harness.respond(
      path: "/v1/hosts/host_a/filesystem",
      body:
        #"{"data":[{"name":"alpha","path":"/home/alpha","type":"directory"},{"name":"notes.txt","path":"/home/notes.txt","type":"file"}],"has_more":true}"#
    )
    harness.respond(
      path: "/v1/hosts/host_a/filesystem", after: "/home/notes.txt",
      body:
        #"{"data":[{"name":"project","path":"/home/project","type":"directory"},{"name":"bad","path":"relative","type":"directory"}],"has_more":false}"#
    )
    let client = try await connected(harness)
    let values = try await client.creationWorkspaces(hostID: "host_a")
    XCTAssertEqual(values.map(\.path), ["/home/alpha", "/home/project"])
    XCTAssertTrue(harness.requests.allSatisfy { $0.httpMethod == "GET" })
  }

  func testRepeatedDirectoryCursorStopsInsteadOfLooping() async throws {
    let harness = stub()
    harness.respond(
      path: "/v1/hosts/host_a/filesystem",
      body: #"{"data":[{"name":"a","path":"/a","type":"directory"}],"has_more":true}"#)
    let client = try await connected(harness)
    do {
      _ = try await client.creationWorkspaces(hostID: "host_a")
      XCTFail("Expected invalid pagination")
    } catch { XCTAssertEqual(error as? LocalServerClientError, .invalidPagination) }
  }

  func test201PostsExactExternalHostContractWithoutInitialPrompt() async throws {
    let harness = stub()
    let client = try await connected(harness)
    var value = selection
    value.model = "provider-model"
    value.workspace = " /work/project "
    let receipt = try await client.createSession(selection: value, title: " Review ")
    XCTAssertEqual(receipt.sessionID, "conv_created")
    XCTAssertEqual(receipt.summary?.id, "conv_created")
    let writes = harness.requests.filter { $0.httpMethod == "POST" }
    XCTAssertEqual(writes.count, 1)
    let request = try XCTUnwrap(writes.first)
    let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
    XCTAssertEqual(
      body,
      .object([
        "agent_id": .string("ag_codex"), "host_id": .string("host_a"),
        "host_type": .string("external"), "workspace": .string("/work/project"),
        "title": .string("Review"), "model_override": .string("provider-model"),
        "labels": .object([
          "omnigent.ui": .string("terminal"), "omnigent.wrapper": .string("codex-native-ui"),
        ]),
      ]))
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertFalse(harness.requests.contains { $0.url?.path.hasSuffix("/events") == true })
  }

  func testDefaultsOmitModelAndBlankTitle() async throws {
    let harness = stub()
    let client = try await connected(harness)
    _ = try await client.createSession(selection: selection, title: " \n ")
    let request = try XCTUnwrap(harness.requests.first { $0.httpMethod == "POST" })
    let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody)).object
    XCTAssertNil(body?["model_override"])
    XCTAssertNil(body?["title"])
    XCTAssertNil(body?["initial_items"])
    XCTAssertNil(body?["harness_override"])
    XCTAssertNil(body?["terminal_launch_args"])
    XCTAssertFalse(harness.requests.contains { $0.url?.path.hasSuffix("model-options") == true })
  }

  func testReadinessAndModelAreRevalidatedImmediatelyBeforePost() async throws {
    let harness = stub()
    let client = try await connected(harness)
    _ = try await client.sessionCreationCatalog()
    harness.respond(
      path: "/v1/hosts",
      body:
        #"{"hosts":[{"host_id":"host_a","name":"Mac","status":"offline","configured_harnesses":{"codex-native":true}}]}"#
    )
    do {
      _ = try await client.createSession(selection: selection, title: "")
      XCTFail("Offline creation")
    } catch { XCTAssertTrue(error is SessionCreationError) }
    XCTAssertFalse(harness.requests.contains { $0.httpMethod == "POST" })
  }

  func testUnadvertisedModelBlocksPostButDefaultNeedsNoModelCatalog() async throws {
    let harness = stub()
    harness.respond(
      path: "/v1/hosts/host_a/harnesses/codex-native/model-options",
      body: #"{"models":[{"id":"provider-model","hidden":true}]}"#)
    let client = try await connected(harness)
    var value = selection
    value.model = "provider-model"
    do {
      _ = try await client.createSession(selection: value, title: "")
      XCTFail("Hidden model")
    } catch { XCTAssertTrue(error is SessionCreationError) }
    XCTAssertFalse(harness.requests.contains { $0.httpMethod == "POST" })
    _ = try await client.createSession(selection: selection, title: "")
    XCTAssertEqual(harness.requests.filter { $0.httpMethod == "POST" }.count, 1)
  }

  func testAcceptedIDSurvivesUnknownSnapshotShapeAndFailedHydration() async throws {
    let harness = stub()
    harness.respond(
      path: "/v1/sessions", body: #"{"id":"conv_created","status":"future-status"}"#, status: 201,
      method: "POST")
    let client = try await connected(harness)
    let receipt = try await client.createSession(selection: selection, title: "")
    XCTAssertEqual(receipt.sessionID, "conv_created")
    XCTAssertNil(receipt.summary)
    do {
      _ = try await client.conversation(id: receipt.sessionID)
      XCTFail("Unstubbed hydration")
    } catch {}
    XCTAssertEqual(harness.requests.filter { $0.httpMethod == "POST" }.count, 1)
    XCTAssertFalse(harness.requests.contains { $0.url?.path.hasSuffix("/events") == true })
  }

  func testUncertainWritesAreNeverAutomaticallyRetried() async throws {
    let cases: [TransportHarness.Stub] = [
      .init(body: "", errorCode: .networkConnectionLost), .init(body: "", errorCode: .timedOut),
      .init(body: "", errorCode: .cancelled), .init(body: "{}", status: 201),
      .init(body: "<html>proxy</html>", status: 201), .init(body: "{}", status: 500),
      .init(body: "{}", status: 409), .init(body: "{}", status: 404),
      .init(body: "{}", status: 403), .init(body: "{}", status: 302),
      .init(body: #"{"id":"../other"}"#, status: 201),
    ]
    for response in cases {
      let harness = stub()
      harness.enqueue(path: "/v1/sessions", method: "POST", stubs: [response])
      let client = try await connected(harness)
      do {
        _ = try await client.createSession(selection: selection, title: "")
        XCTFail("Expected uncertain delivery")
      } catch { XCTAssertEqual(error as? SessionCreationError, .uncertain) }
      XCTAssertEqual(harness.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }
  }

  func testValidationRejectionProvidesServerExplanation() async throws {
    let harness = stub()
    harness.respond(
      path: "/v1/sessions", body: #"{"error":{"message":"workspace does not exist"}}"#, status: 400,
      method: "POST")
    let client = try await connected(harness)
    do {
      _ = try await client.createSession(selection: selection, title: "")
      XCTFail("Expected rejection")
    } catch {
      XCTAssertEqual(
        error as? SessionCreationError, .rejected(status: 400, message: "workspace does not exist"))
    }
    XCTAssertEqual(harness.requests.filter { $0.httpMethod == "POST" }.count, 1)
  }

  private func catalog() -> SessionCreationCatalog {
    SessionCreationCatalog(
      hosts: [
        CreationHost(
          hostID: "host_a", name: "Mac", status: "online",
          configuredHarnesses: ["codex-native": .ready])
      ],
      agents: [CreationAgent(id: "ag_codex", name: "Custom Codex", harness: "codex-native")])
  }

  private func stub() -> TransportHarness {
    let harness = TransportHarness()
    harness.respond(
      path: "/v1/hosts",
      body:
        #"{"hosts":[{"host_id":"host_a","name":"Mac","status":"online","configured_harnesses":{"codex-native":true}}]}"#
    )
    harness.respond(
      path: "/v1/agents",
      body:
        #"{"data":[{"id":"ag_codex","name":"Custom Codex","harness":"codex-native"}],"has_more":false}"#
    )
    harness.respond(
      path: "/v1/hosts/host_a/harnesses/codex-native/model-options",
      body: #"{"models":[{"id":"model-choice","model":"provider-model"}]}"#)
    harness.respond(
      path: "/v1/sessions",
      body:
        #"{"id":"conv_created","status":"idle","created_at":1,"agent_id":"ag_codex","host_id":"host_a","harness":"codex-native","permission_level":4}"#,
      status: 201, method: "POST")
    return harness
  }

  private func connected(_ harness: TransportHarness) async throws -> LocalServerSessionClient {
    let client = try harness.makeClient()
    _ = try await client.connect()
    return client
  }
}
