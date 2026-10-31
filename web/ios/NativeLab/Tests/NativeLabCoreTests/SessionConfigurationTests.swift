import Foundation
import XCTest

@testable import NativeLabCore

final class SessionConfigurationTests: XCTestCase {
  func testMissingIdentifiersAreNotDefaultsOrModelMatches() throws {
    let choice = ModelChoice(id: "m1")
    XCTAssertFalse(choice.matches(nil))
    XCTAssertTrue(choice.matches("m1"))
    XCTAssertFalse(choice.matches("unknown"))
    let missing = try summary([:]).configuration!
    XCTAssertEqual(missing.harnessLabel, "Harness not reported")
    XCTAssertEqual(missing.modelLabel, "Model not reported")
    XCTAssertEqual(missing.effortLabel, "Not reported")
    let cleared = try summary(["model_override": NSNull(), "reasoning_effort": NSNull()])
      .configuration!
    XCTAssertEqual(cleared.modelLabel, "Harness default")
    XCTAssertEqual(cleared.effortLabel, "Harness default")
  }

  func testUnknownIDsRemainVisibleAndUnchangedSelectionIsValid() throws {
    var current = SessionConfiguration.demo
    current.harness = "future-harness"
    current.modelOverride = "provider.unlisted-model"
    current.effort = "future-effort"
    XCTAssertEqual(current.identityLabel, "future-harness · provider.unlisted-model")
    XCTAssertEqual(current.effortLabel, "Future-Effort")
    XCTAssertNoThrow(try ConfigurationEdit(current).validate(against: current))
  }

  func testDefaultEffortUsesRunnerDefaultNotAgentSpecModel() {
    var current = SessionConfiguration.demo
    current.baseModel = "sample-fast"
    XCTAssertEqual(current.efforts(for: nil), ["low", "high"])
    XCTAssertEqual(current.efforts(for: "sample-fast"), ["low"])
    current.models = [
      ModelChoice(
        id: "sample-fast", supportedReasoningEfforts: [ReasoningChoice(reasoningEffort: "low")])
    ]
    XCTAssertEqual(current.efforts(for: nil), [])
    XCTAssertEqual(current.efforts(for: "not-advertised"), [])
  }

  func testSelectingModelClearsOnlyUnsupportedEffort() throws {
    var current = SessionConfiguration.demo
    current.effort = "high"
    var edit = ConfigurationEdit(current)
    edit.selectModel("sample-fast")
    XCTAssertNil(edit.effort)
    XCTAssertTrue(edit.hasChanges)
    XCTAssertNoThrow(try edit.validate(against: current))
    edit.effort = "high"
    XCTAssertThrowsError(try edit.validate(against: current))
    edit.effort = "low"
    XCTAssertNoThrow(try edit.validate(against: current))
  }

  func testHiddenAndUnknownModelsCannotBeNewSelections() throws {
    var current = SessionConfiguration.demo
    current.models.append(ModelChoice(id: "hidden", hidden: true))
    for model in ["hidden", "unknown"] {
      var edit = ConfigurationEdit(current)
      edit.model = model
      XCTAssertThrowsError(try edit.validate(against: current))
    }
    current.modelOverride = "hidden"
    XCTAssertNoThrow(try ConfigurationEdit(current).validate(against: current))
    var edit = ConfigurationEdit(current)
    edit.model = "sample-fast"
    current.routingMode = "on"
    edit = ConfigurationEdit(current)
    edit.model = "sample-fast"
    XCTAssertThrowsError(try edit.validate(against: current))
    XCTAssertEqual(current.modelLabel, "Smart routing")
  }

  func testCatalogChangesRevalidateChoicesButDoNotInventSelectionConflict() throws {
    let original = SessionConfiguration.demo
    var edit = ConfigurationEdit(original)
    edit.model = "sample-fast"
    var current = original
    current.models.removeAll { $0.id == "sample-fast" }
    XCTAssertTrue(original.sameSelection(as: current))
    XCTAssertThrowsError(try edit.validate(against: current))
    current = original
    current.effort = "high"
    XCTAssertThrowsError(try edit.validate(against: current)) { error in
      XCTAssertEqual(error as? ConfigurationError, .changedElsewhere)
    }
  }

  func testPartialListProjectionPreservesConfigurationButExplicitNullClearsIt() throws {
    let detailed = try summary(configurationFields())
    let listed = try summary([:], previous: detailed)
    XCTAssertEqual(listed.configuration, detailed.configuration)
    let reset = try summary(
      [
        "model_override": NSNull(), "reasoning_effort": NSNull(), "model_options": [],
        "host_online": false, "runner_online": NSNull(),
      ], previous: detailed)
    XCTAssertNil(reset.configuration?.modelOverride)
    XCTAssertNil(reset.configuration?.effort)
    XCTAssertEqual(reset.configuration?.models, [])
    XCTAssertEqual(reset.configuration?.hostOnline, false)
    XCTAssertNil(reset.configuration?.runnerOnline)
    XCTAssertEqual(reset.configuration?.harness, "codex-native")
  }

  func testHarnessAndHostChangesDoNotBorrowStaleCapabilities() throws {
    let detailed = try summary(configurationFields())
    let switched = try summary(
      ["harness": "claude-native", "agent_id": "new-agent"], previous: detailed)
    XCTAssertEqual(switched.configuration?.models, [])
    XCTAssertNil(switched.configuration?.wrapper)
    XCTAssertNil(switched.configuration?.modelOverride)
    let moved = try summary(["host_id": "different-host"], previous: detailed)
    XCTAssertNil(moved.configuration?.hostOnline)
    XCTAssertNil(moved.configuration?.runnerOnline)
  }

  func testConfigurationFlagsDecodeFromOlderSavedConfiguration() throws {
    let encoded = try JSONEncoder().encode(SessionConfiguration.demo)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "modelReported")
    object.removeValue(forKey: "effortReported")
    let restored = try JSONDecoder().decode(
      SessionConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(restored.modelOverride, "sample-balanced")
    XCTAssertNil(restored.effortReported)
  }

  func testHarnessSafetyRequiresCorrectOnlineConfiguredHostAndHistorySupport() {
    let current = SessionConfiguration.demo
    let target = HarnessChoice(
      id: "target", name: "Claude", harness: "claude-native", builtin: true)
    XCTAssertNil(ConfigurationCatalog.demo.unavailableReason(for: target, current: current))
    let unsafe = HarnessChoice(
      id: "cursor", name: "Cursor", harness: "cursor-native", builtin: true)
    XCTAssertNotNil(ConfigurationCatalog.demo.unavailableReason(for: unsafe, current: current))
    let otherHost = ConfigurationCatalog(
      agents: [target],
      host: ConfigurationHost(
        hostID: "other", name: "Other", status: "online",
        configuredHarnesses: ["claude-native": .bool(true)]))
    XCTAssertNotNil(otherHost.unavailableReason(for: target, current: current))
    let needsAuth = ConfigurationCatalog(
      agents: [target],
      host: ConfigurationHost(
        hostID: "demo-host", name: "Host", status: "online",
        configuredHarnesses: ["claude-native": .string("needs-auth")]))
    XCTAssertEqual(
      needsAuth.unavailableReason(for: target, current: current),
      "Sign in to this harness on the host first.")
    var child = current
    child.parentID = "parent"
    XCTAssertNotNil(ConfigurationCatalog.demo.unavailableReason(for: target, current: child))
    let same = HarnessChoice(
      id: "different-clone", name: "Codex", harness: "native-codex", builtin: true)
    XCTAssertEqual(
      ConfigurationCatalog.demo.unavailableReason(for: same, current: current), "Current harness")
    let scoped = HarnessChoice(
      id: "scoped", name: "Claude", harness: "claude-native", builtin: false)
    XCTAssertNotNil(ConfigurationCatalog.demo.unavailableReason(for: scoped, current: current))
  }

  func testProviderFamiliesMatchBackendCarrySettingsPolicy() {
    for harness in [
      "codex-native", "native-codex", "qwen", "qwen-native", "native-qwen", "antigravity",
      "openai-agents-sdk",
    ] {
      XCTAssertEqual(SessionConfiguration.family(harness), "openai", harness)
    }
    XCTAssertEqual(SessionConfiguration.family("native-claude"), "anthropic")
    XCTAssertEqual(SessionConfiguration.family("native-antigravity"), "gemini")
    XCTAssertNil(SessionConfiguration.family("pi-native"))
    XCTAssertNil(SessionConfiguration.family("unknown"))
  }

  func testModelAndEffortPatchAreOrderedAndUseExplicitResetSentinels() async throws {
    let harness = TransportHarness()
    let original = configurationFields()
    var afterModel = original
    afterModel["model_override"] = NSNull()
    var afterEffort = afterModel
    afterEffort["reasoning_effort"] = NSNull()
    harness.enqueue(
      path: path, method: "GET",
      stubs: [
        .init(body: try wire(original)), .init(body: try wire(afterModel)),
      ])
    harness.enqueue(
      path: path, method: "PATCH",
      stubs: [
        .init(body: try wire(afterModel)), .init(body: try wire(afterEffort)),
      ])
    let client = try await client(harness)
    var edit = ConfigurationEdit(try XCTUnwrap(summary(original).configuration))
    edit.model = nil
    edit.effort = nil
    let saved = try await client.applyConfiguration(edit, sessionID: "conv_a")
    XCTAssertNil(saved.configuration?.modelOverride)
    XCTAssertNil(saved.configuration?.effort)
    let bodies = try mutationBodies(harness)
    XCTAssertEqual(
      bodies, [["model_override": .string("default")], ["reasoning_effort": .string("default")]])
    await client.stopWatching()
  }

  func testBusyReadOnlyArchivedOfflineAndUnstreamedSessionsNeverPatch() async throws {
    let scenarios: [[String: Any]] = [
      ["status": "running"], ["permission_level": 1], ["archived": true],
      ["host_online": false, "runner_online": false], ["pending_elicitations_count": 1],
    ]
    for scenario in scenarios {
      let harness = TransportHarness()
      let fields = configurationFields().merging(scenario) { _, new in new }
      harness.respond(path: path, body: try wire(fields))
      let client = try await client(harness)
      var edit = ConfigurationEdit(try XCTUnwrap(summary(fields).configuration))
      edit.model = "sample-fast"
      do {
        _ = try await client.applyConfiguration(edit, sessionID: "conv_a")
        XCTFail("Expected guard: \(scenario)")
      } catch {}
      XCTAssertEqual(try mutationBodies(harness), [])
      await client.stopWatching()
    }
    let harness = TransportHarness()
    harness.respond(path: path, body: try wire(configurationFields()))
    let client = try harness.makeClient()
    _ = try await client.connect()
    var edit = ConfigurationEdit(try XCTUnwrap(summary(configurationFields()).configuration))
    edit.model = "sample-fast"
    do {
      _ = try await client.applyConfiguration(edit, sessionID: "conv_a")
      XCTFail("Expected stream guard")
    } catch { XCTAssertEqual(error as? LocalServerClientError, .streamNotReady) }
    XCTAssertEqual(try mutationBodies(harness), [])
  }

  func testChangedSelectionAndRemovedCatalogOptionNeverPatch() async throws {
    for fields in [
      configurationFields().merging(["model_override": "external-model"]) { _, new in new },
      configurationFields().merging(["model_options": []]) { _, new in new },
    ] {
      let harness = TransportHarness()
      harness.respond(path: path, body: try wire(fields))
      let client = try await client(harness)
      var edit = ConfigurationEdit(try XCTUnwrap(summary(configurationFields()).configuration))
      edit.model = "sample-fast"
      do {
        _ = try await client.applyConfiguration(edit, sessionID: "conv_a")
        XCTFail("Expected conflict")
      } catch {}
      XCTAssertEqual(try mutationBodies(harness), [])
      await client.stopWatching()
    }
  }

  func testUncertainModelPatchIsNeverRetriedOrFollowedByEffortPatch() async throws {
    let harness = TransportHarness()
    let fields = configurationFields()
    harness.respond(path: path, body: try wire(fields))
    harness.enqueue(
      path: path, method: "PATCH", stubs: [.init(body: "", errorCode: .networkConnectionLost)])
    let client = try await client(harness)
    var edit = ConfigurationEdit(try XCTUnwrap(summary(fields).configuration))
    edit.selectModel("sample-fast")
    do {
      _ = try await client.applyConfiguration(edit, sessionID: "conv_a")
      XCTFail("Expected uncertain delivery")
    } catch { XCTAssertEqual(error as? LocalServerClientError, .deliveryUncertain) }
    XCTAssertEqual(try mutationBodies(harness).count, 1)
    await client.stopWatching()
  }

  func testPartialSuccessRequiresReviewWhenSecondWriteFails() async throws {
    let harness = TransportHarness()
    let original = configurationFields()
    let afterModel = original.merging(["model_override": "sample-fast"]) { _, new in new }
    harness.enqueue(
      path: path, method: "GET",
      stubs: [.init(body: try wire(original)), .init(body: try wire(afterModel))])
    harness.enqueue(
      path: path, method: "PATCH",
      stubs: [.init(body: try wire(afterModel)), .init(body: "{}", status: 403)])
    let client = try await client(harness)
    var edit = ConfigurationEdit(try XCTUnwrap(summary(original).configuration))
    edit.selectModel("sample-fast")
    do {
      _ = try await client.applyConfiguration(edit, sessionID: "conv_a")
      XCTFail("Expected partial outcome")
    } catch { XCTAssertEqual(error as? LocalServerClientError, .deliveryUncertain) }
    XCTAssertEqual(try mutationBodies(harness).count, 2)
    await client.stopWatching()
  }

  func testUnacknowledgedAndMalformedMutationSnapshotsAreUncertain() async throws {
    let original = configurationFields()
    for response in [
      try wire(original), try wire(original.merging(["status": "unknown-state"]) { _, new in new }),
      "{}",
    ] {
      let harness = TransportHarness()
      harness.respond(path: path, body: try wire(original))
      harness.respond(path: path, body: response, method: "PATCH")
      let client = try await client(harness)
      var edit = ConfigurationEdit(try XCTUnwrap(summary(original).configuration))
      edit.selectModel("sample-fast")
      do {
        _ = try await client.applyConfiguration(edit, sessionID: "conv_a")
        XCTFail("Expected uncertain acknowledgement")
      } catch { XCTAssertEqual(error as? LocalServerClientError, .deliveryUncertain) }
      XCTAssertEqual(try mutationBodies(harness).count, 1)
      await client.stopWatching()
    }
  }

  func testStreamEventCrossingSnapshotReadRejectsStaleConfiguration() async throws {
    let harness = TransportHarness()
    harness.enqueue(
      path: path, method: "GET", stubs: [.init(body: try wire(configurationFields()), delay: 0.2)])
    let client = try await client(harness)
    harness.observeRequests { request in
      if request.url?.path == self.path {
        Task {
          await client.recordConfigurationEvent(
            ["type": .string("session.model"), "model": .string("new")], sessionID: "conv_a")
        }
      }
    }
    do {
      _ = try await client.configurationSnapshot("conv_a")
      XCTFail("Expected crossed-event rejection")
    } catch { XCTAssertEqual(error as? ConfigurationError, .changedElsewhere) }
    let cached = await client.summaries["conv_a"]
    XCTAssertNil(cached)
    await client.stopWatching()
  }

  func testListEventCrossingSnapshotReadRejectsStaleConfiguration() async throws {
    let harness = TransportHarness()
    harness.enqueue(
      path: path, method: "GET", stubs: [.init(body: try wire(configurationFields()), delay: 0.2)])
    let client = try await client(harness)
    let changed = try wire(
      configurationFields().merging(["model_override": "external"]) { _, new in new })
    harness.observeRequests { request in
      if request.url?.path == self.path {
        Task {
          do {
            try await client.handleListMessage(
              Data("{\"type\":\"changed\",\"items\":[\(changed)]}".utf8))
          } catch { XCTFail("Invalid test list frame: \(error)") }
        }
      }
    }
    do {
      _ = try await client.configurationSnapshot("conv_a")
      XCTFail("Expected crossed-list rejection")
    } catch { XCTAssertEqual(error as? ConfigurationError, .changedElsewhere) }
    let cached = await client.summaries["conv_a"]
    XCTAssertEqual(cached?.configuration?.modelOverride, "external")
    await client.stopWatching()
  }

  func testHarnessSwitchRetainsSessionAndChecksTargetAcknowledgement() async throws {
    let harness = TransportHarness()
    let original = configurationFields()
    harness.respond(path: path, body: try wire(original))
    harness.respond(
      path: "/v1/hosts",
      body:
        #"{"hosts":[{"host_id":"demo-host","name":"Host","status":"online","configured_harnesses":{"claude-native":true}}]}"#
    )
    harness.respond(
      path: "/v1/agents",
      body:
        #"{"data":[{"id":"target","name":"Claude","harness":"claude-native","builtin":true}],"has_more":false}"#
    )
    let switched = original.merging([
      "agent_id": "target-clone", "harness": "claude-native", "model_override": NSNull(),
      "reasoning_effort": NSNull(), "labels": ["omnigent.wrapper": "claude-code-native-ui"],
    ]) { _, new in new }
    harness.respond(path: "\(path)/switch-agent", body: try wire(switched), method: "POST")
    let client = try await client(harness)
    let saved = try await client.switchHarness(
      to: "target", baseline: XCTUnwrap(summary(original).configuration), sessionID: "conv_a")
    XCTAssertEqual(saved.id, "conv_a")
    XCTAssertEqual(saved.configuration?.harness, "claude-native")
    XCTAssertNil(saved.configuration?.modelOverride)
    XCTAssertEqual(try mutationBodies(harness), [["agent_id": .string("target")]])
    await client.stopWatching()
  }

  func testDemoUpgradeAndNewSessionsPublishReportedConfiguration() async throws {
    let original = DemoFixtures.snapshots[0]
    let client = DemoSessionClient(initialSnapshots: [original])
    let upgraded = try await client.conversation(id: original.id)
    XCTAssertEqual(upgraded.revision, original.revision + 1)
    XCTAssertEqual(upgraded.session.configuration, .demo)
    let created = try await client.createSession(title: "Configuration test")
    XCTAssertEqual(created.session.configuration, .demo)
    var edit = ConfigurationEdit(.demo)
    edit.selectModel("sample-fast")
    let configured = try await client.configure(sessionID: created.id, edit: edit)
    XCTAssertEqual(configured.session.configuration?.modelOverride, "sample-fast")
    XCTAssertEqual(configured.messages, created.messages)
  }

  func testHostPreviewStaysSeparateAndCannotFollowAnotherHarness() async throws {
    let harness = TransportHarness()
    let fields = configurationFields().merging(["model_options": []]) { _, new in new }
    harness.respond(path: path, body: try wire(fields))
    configureHostCatalog(harness)
    harness.respond(
      path: modelOptionsPath,
      body: #"{"models":[{"id":"sample-fast","displayName":"Fast from host"}]}"#)
    let client = try await client(harness)
    let catalog = try await client.configurationCatalog(sessionID: "conv_a")
    XCTAssertEqual(catalog.modelOptions.map(\.id), ["sample-fast"])
    XCTAssertNil(catalog.modelOptionsError)
    let current = try XCTUnwrap(summary(fields).configuration)
    XCTAssertEqual(
      catalog.configurationByAddingModelOptions(to: current).models, catalog.modelOptions)
    var switched = current
    switched.harness = "claude-native"
    XCTAssertEqual(catalog.configurationByAddingModelOptions(to: switched).models, [])
    let confirmed = await client.summaries["conv_a"]?.configuration
    XCTAssertEqual(confirmed?.models, [])
    XCTAssertEqual(try mutationBodies(harness), [])
    await client.stopWatching()
  }

  func testHostPreviewFailureDoesNotHideHarnessCatalog() async throws {
    let harness = TransportHarness()
    harness.respond(
      path: path,
      body: try wire(configurationFields().merging(["model_options": []]) { _, new in new }))
    configureHostCatalog(harness)
    harness.respond(path: modelOptionsPath, body: "{}", status: 502)
    let client = try await client(harness)
    let catalog = try await client.configurationCatalog(sessionID: "conv_a")
    XCTAssertEqual(catalog.agents.count, 1)
    XCTAssertEqual(catalog.modelOptions, [])
    XCTAssertNotNil(catalog.modelOptionsError)
    await client.stopWatching()
  }

  func testApplyRevalidatesHostPreviewBeforeAnyWrite() async throws {
    let harness = TransportHarness()
    let fields = configurationFields().merging(["model_options": []]) { _, new in new }
    harness.respond(path: path, body: try wire(fields))
    harness.respond(path: modelOptionsPath, body: #"{"models":[{"id":"different-model"}]}"#)
    let client = try await client(harness)
    var edit = ConfigurationEdit(try XCTUnwrap(summary(fields).configuration))
    edit.model = "sample-fast"
    edit.effort = nil
    do {
      _ = try await client.applyConfiguration(edit, sessionID: "conv_a")
      XCTFail("Removed preview model must be rejected")
    } catch { XCTAssertNotNil(error as? ConfigurationError) }
    XCTAssertEqual(try mutationBodies(harness), [])
    XCTAssertEqual(harness.requests.filter { $0.url?.path == modelOptionsPath }.count, 1)
    await client.stopWatching()
  }

  func testChangedEventDuringMutationUsesFreshAcknowledgementNotStaleResponse() async throws {
    let harness = TransportHarness()
    let fields = configurationFields()
    let desired = fields.merging(["model_override": "sample-fast", "reasoning_effort": NSNull()]) {
      _, new in new
    }
    let external = fields.merging(["model_override": "external-model"]) { _, new in new }
    harness.enqueue(
      path: path, method: "GET",
      stubs: [.init(body: try wire(fields)), .init(body: try wire(external))])
    harness.respond(path: path, body: try wire(external))
    harness.enqueue(
      path: path, method: "PATCH", stubs: [.init(body: try wire(desired), delay: 0.2)])
    let client = try await client(harness)
    harness.observeRequests { request in
      if request.httpMethod == "PATCH" {
        Task {
          await client.recordConfigurationEvent(
            ["type": .string("session.model"), "model": .string("external-model")],
            sessionID: "conv_a")
        }
      }
    }
    var edit = ConfigurationEdit(try XCTUnwrap(summary(fields).configuration))
    edit.selectModel("sample-fast")
    do {
      _ = try await client.applyConfiguration(edit, sessionID: "conv_a")
      XCTFail("Expected changed outcome")
    } catch { XCTAssertEqual(error as? LocalServerClientError, .deliveryUncertain) }
    let confirmed = await client.summaries["conv_a"]?.configuration
    XCTAssertEqual(confirmed?.modelOverride, "external-model")
    XCTAssertEqual(try mutationBodies(harness).count, 1)
    await client.stopWatching()
  }

  func testConcurrentConfigurationMutationIsRejectedBeforeSecondWrite() async throws {
    let harness = TransportHarness()
    let fields = configurationFields().merging(["reasoning_effort": NSNull()]) { _, new in new }
    let saved = fields.merging(["model_override": "sample-fast"]) { _, new in new }
    harness.respond(path: path, body: try wire(fields))
    harness.enqueue(path: path, method: "PATCH", stubs: [.init(body: try wire(saved), delay: 0.2)])
    let client = try await client(harness)
    let started = expectation(description: "First mutation submitted")
    harness.observeRequests { if $0.httpMethod == "PATCH" { started.fulfill() } }
    var edit = ConfigurationEdit(try XCTUnwrap(summary(fields).configuration))
    edit.selectModel("sample-fast")
    let first = Task { try await client.applyConfiguration(edit, sessionID: "conv_a") }
    await fulfillment(of: [started], timeout: 2)
    do {
      _ = try await client.applyConfiguration(edit, sessionID: "conv_a")
      XCTFail("Concurrent mutation should be busy")
    } catch { XCTAssertEqual(error as? SessionClientError, .busy) }
    _ = try await first.value
    XCTAssertEqual(try mutationBodies(harness).count, 1)
    await client.stopWatching()
  }

  private var modelOptionsPath: String {
    "/v1/hosts/demo-host/harnesses/codex-native/model-options"
  }

  func testMetadataVersionRejectsOlderCallbacksWithoutChangingConversationIdentity() {
    var older = SessionSummary(
      id: "same", title: "Old", preview: "", configuration: .demo, configurationRevision: 4)
    var newer = older
    newer.title = "New"
    newer.configuration?.modelOverride = "sample-fast"
    newer.configurationRevision = 5
    XCTAssertEqual(older.preservingNewerMetadata(from: newer), newer)
    XCTAssertEqual(newer.preservingNewerMetadata(from: older), newer)
    older.configurationRevision = nil
    XCTAssertEqual(older.preservingNewerMetadata(from: newer), newer)
    let other = SessionSummary(id: "other", title: "Other", preview: "", configurationRevision: 100)
    XCTAssertEqual(older.preservingNewerMetadata(from: other), older)
  }

  func testSlowHistoryCannotRollbackNewerMetadata() async throws {
    let harness = TransportHarness()
    let fields = configurationFields()
    let changed = try wire(fields.merging(["model_override": "external-model"]) { _, new in new })
    harness.respond(path: path, body: try wire(fields))
    harness.enqueue(
      path: "\(path)/items", method: "GET",
      stubs: [.init(body: #"{"data":[],"has_more":false}"#, delay: 0.2)])
    let client = try await client(harness)
    harness.observeRequests { request in
      if request.url?.path == "\(self.path)/items" {
        Task {
          do {
            try await client.handleListMessage(
              Data("{\"type\":\"changed\",\"items\":[\(changed)]}".utf8))
          } catch { XCTFail("Invalid test event: \(error)") }
        }
      }
    }
    let page = try await client.conversationPage(id: "conv_a")
    XCTAssertEqual(page.snapshot.session.configuration?.modelOverride, "external-model")
    XCTAssertNotNil(page.snapshot.session.configurationRevision)
    await client.stopWatching()
  }

  func testSlowListAndInventoryCannotRollbackNewerMetadata() async throws {
    for inventory in [false, true] {
      let harness = TransportHarness()
      let original = try wire(configurationFields())
      let changed = try wire(
        configurationFields().merging(["model_override": "external-model"]) { _, new in new })
      harness.enqueue(
        path: "/v1/sessions", method: "GET",
        stubs: [.init(body: "{\"data\":[\(original)],\"has_more\":false}", delay: 0.2)])
      let client = try await client(harness)
      harness.observeRequests { request in
        if request.url?.path == "/v1/sessions" {
          Task {
            do {
              try await client.handleListMessage(
                Data("{\"type\":\"changed\",\"items\":[\(changed)]}".utf8))
            } catch { XCTFail("Invalid test event: \(error)") }
          }
        }
      }
      let sessions =
        inventory ? try await client.sessionInventory() : try await client.sessionPage().sessions
      XCTAssertEqual(sessions.first?.configuration?.modelOverride, "external-model")
      await client.stopWatching()
    }
  }

  func testHydrationCompletionPreservesAcknowledgedConfigurationAndSchedulesFollowup() async throws
  {
    let harness = TransportHarness()
    let original = try summary(configurationFields())
    let changed = configurationFields().merging(["model_override": "external-model"]) { _, new in
      new
    }
    harness.respond(path: path, body: try wire(changed))
    let client = try await client(harness)
    _ = try await client.configurationSnapshot("conv_a")
    let page = LocalConversationPage(
      snapshot: ConversationSnapshot(revision: 1, session: original, messages: []), nextCursor: nil)
    let generation = await client.streamGeneration
    try await client.finishHydration(page, generation: generation)
    let confirmed = await client.reducer?.snapshot.session.configuration
    XCTAssertEqual(confirmed?.modelOverride, "external-model")
    await client.markHydratingForTesting()
    await client.rehydrateAfterMutation(sessionID: "conv_a")
    let requested = await client.hydrationRequestedAgain
    XCTAssertTrue(requested)
    await client.stopWatching()
  }

  func testStableConfigurationReadSupersedesBufferedSettingsButKeepsText() async throws {
    let harness = TransportHarness()
    harness.respond(path: path, body: try wire(configurationFields()))
    let client = try await client(harness)
    await client.bufferSettingsAndTextForTesting()
    _ = try await client.configurationSnapshot("conv_a")
    let remaining = await client.bufferedEvents
    XCTAssertEqual(remaining.map { $0["type"]?.string }, ["response.output_text.delta"])
    await client.stopWatching()
  }

  func testListReadAlsoUpdatesReducerBeforeNextStreamPublication() async throws {
    let harness = TransportHarness()
    let changed = try wire(
      configurationFields().merging(["model_override": "external-model"]) { _, new in new })
    harness.respond(path: "/v1/sessions", body: "{\"data\":[\(changed)],\"has_more\":false}")
    let client = try await client(harness)
    let original = try summary(configurationFields())
    await client.seedReducerForTesting(original)
    _ = try await client.sessionPage()
    await client.publishSnapshot()
    let published = await client.reducer?.snapshot.session
    XCTAssertEqual(published?.configuration?.modelOverride, "external-model")
    await client.stopWatching()
  }

  func testSparseListChangeLoadsExternalModelWithoutRunnerEchoOrPolling() async throws {
    try await assertSparseConfigurationHydration(frameType: "changed")
  }

  func testSparseReconnectSnapshotLoadsMissedExternalModel() async throws {
    try await assertSparseConfigurationHydration(frameType: "snapshot")
  }

  func testSparseListUpdateDoesNotHydrateOrReviveStoppedConversationStream() async throws {
    let harness = TransportHarness()
    let client = try await client(harness)
    await client.stopTransportForTesting()
    let count = harness.requests.count
    try await client.handleListMessage(
      Data(
        #"{"type":"changed","items":[{"id":"conv_a","agent_id":"clone","status":"idle","created_at":1,"updated_at":2,"permission_level":4}]}"#
          .utf8))
    let ready = await client.streamReady
    let hydrating = await client.isHydrating
    XCTAssertFalse(ready)
    XCTAssertFalse(hydrating)
    XCTAssertEqual(harness.requests.count, count)
    await client.stopWatching()
  }

  private func assertSparseConfigurationHydration(frameType: String) async throws {
    let harness = TransportHarness()
    let original = try summary(configurationFields())
    let updated = configurationFields().merging(["model_override": "external-model"]) { _, new in
      new
    }
    harness.respond(path: path, body: try wire(updated))
    harness.respond(path: "\(path)/items", body: #"{"data":[],"has_more":false}"#)
    let client = try await client(harness)
    await client.seedReducerForTesting(original)
    await client.cacheSummary(original)
    let updates = await client.updates()
    var iterator = updates.makeAsyncIterator()
    _ = await iterator.next()
    try await client.handleListMessage(
      Data(
        #"{"type":"\#(frameType)","items":[{"id":"conv_a","agent_id":"clone","status":"idle","created_at":1,"updated_at":2,"permission_level":4,"reasoning_effort":"high"}]}"#
          .utf8))
    let update = await iterator.next()
    let refreshed = try XCTUnwrap(update)
    XCTAssertEqual(refreshed.session.configuration?.modelOverride, "external-model")
    XCTAssertFalse(original.configuration!.sameSelection(as: refreshed.session.configuration!))
    XCTAssertEqual(
      harness.requests.filter { $0.url?.path == path && $0.httpMethod == "GET" }.count, 1)
    XCTAssertEqual(try mutationBodies(harness), [])
    await client.stopWatching()
  }

  func testSparseChangeHydrationCannotOverwriteLaterCompleteMetadata() async throws {
    let harness = TransportHarness()
    let original = try summary(configurationFields())
    let latest = try wire(
      configurationFields().merging(["model_override": "newer-model"]) { _, new in new })
    harness.enqueue(
      path: path, method: "GET", stubs: [.init(body: try wire(configurationFields()), delay: 0.2)])
    harness.respond(path: "\(path)/items", body: #"{"data":[],"has_more":false}"#)
    let client = try await client(harness)
    await client.seedReducerForTesting(original)
    await client.cacheSummary(original)
    let updates = await client.updates()
    var iterator = updates.makeAsyncIterator()
    _ = await iterator.next()
    harness.observeRequests { request in
      if request.url?.path == self.path {
        Task {
          do {
            try await client.handleListMessage(
              Data("{\"type\":\"changed\",\"items\":[\(latest)]}".utf8))
          } catch { XCTFail("Invalid test event: \(error)") }
        }
      }
    }
    try await client.handleListMessage(
      Data(
        #"{"type":"changed","items":[{"id":"conv_a","agent_id":"clone","status":"idle","created_at":1,"updated_at":2,"permission_level":4}]}"#
          .utf8))
    let update = await iterator.next()
    let refreshed = try XCTUnwrap(update)
    XCTAssertEqual(refreshed.session.configuration?.modelOverride, "newer-model")
    let cached = await client.summaries["conv_a"]
    XCTAssertEqual(cached?.configuration?.modelOverride, "newer-model")
    await client.stopWatching()
  }

  private func configureHostCatalog(_ harness: TransportHarness) {
    harness.respond(
      path: "/v1/hosts",
      body:
        #"{"hosts":[{"host_id":"demo-host","name":"Host","status":"online","configured_harnesses":{"codex-native":true,"claude-native":true}}]}"#
    )
    harness.respond(
      path: "/v1/agents",
      body:
        #"{"data":[{"id":"target","name":"Claude","harness":"claude-native","builtin":true}],"has_more":false}"#
    )
  }

  private let path = "/v1/sessions/conv_a"

  private func client(_ harness: TransportHarness) async throws -> LocalServerSessionClient {
    let client = try harness.makeClient()
    _ = try await client.connect()
    await client.primeStreamForTesting("conv_a")
    await client.primeTransportForTesting()
    return client
  }

  private func mutationBodies(_ harness: TransportHarness) throws -> [[String: JSONValue]] {
    try harness.requests.filter { $0.httpMethod == "PATCH" || $0.httpMethod == "POST" }.map {
      try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: XCTUnwrap($0.httpBody)).object)
    }
  }

  private func configurationFields() -> [String: Any] {
    [
      "harness": "codex-native", "agent_id": "clone",
      "labels": ["omnigent.wrapper": "codex-native-ui"],
      "model_override": "sample-balanced", "reasoning_effort": "high", "host_id": "demo-host",
      "host_online": true, "runner_online": true,
      "model_options": [
        [
          "id": "sample-balanced", "isDefault": true,
          "supportedReasoningEfforts": [["reasoningEffort": "high"], ["reasoningEffort": "low"]],
        ],
        ["id": "sample-fast", "supportedReasoningEfforts": [["reasoningEffort": "low"]]],
      ],
    ]
  }

  private func wire(_ fields: [String: Any]) throws -> String {
    let base: [String: Any] = [
      "id": "conv_a", "status": "idle", "created_at": 1, "permission_level": 4,
    ]
    return String(
      decoding: try JSONSerialization.data(withJSONObject: base.merging(fields) { _, new in new }),
      as: UTF8.self)
  }

  private func summary(_ fields: [String: Any], previous: SessionSummary? = nil) throws
    -> SessionSummary
  {
    try JSONDecoder().decode(SessionWire.self, from: Data(wire(fields).utf8)).summary(
      previous: previous)
  }
}

extension LocalServerSessionClient {
  fileprivate func primeTransportForTesting() {
    streamDataTask = session.dataTask(with: baseURL.appending(path: "/test-suspended-stream"))
  }

  fileprivate func stopTransportForTesting() {
    streamDataTask?.cancel()
    streamDataTask = nil
    receivedHeartbeat = true
    streamReady = false
  }

  fileprivate func markHydratingForTesting() { isHydrating = true }

  fileprivate func bufferSettingsAndTextForTesting() {
    bufferedEvents = [
      ["type": .string("session.model"), "model": .string("older-model")],
      ["type": .string("response.output_text.delta"), "delta": .string("Keep text")],
    ]
  }

  fileprivate func seedReducerForTesting(_ summary: SessionSummary) {
    reducer = LiveConversationReducer(
      snapshot: ConversationSnapshot(revision: 1, session: summary, messages: []))
  }
}
