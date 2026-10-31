import Foundation
import XCTest

@testable import NativeLabCore

/// Independent fixtures mirror the web contract rather than generated native demo data.
final class EventParityTests: XCTestCase {
  func testAllSixteenPersistedFamiliesHaveMeaningfulTypedPresentation() throws {
    let fixtures: [(String, ConversationActivity.Kind?, String, String)] = [
      (
        "message", nil,
        #"{"role":"assistant","content":[{"type":"output_text","text":"Visible reply"}]}"#,
        "Visible reply"
      ),
      (
        "function_call", .toolCall,
        #"{"name":"lookup","arguments":"{\"query\":\"typed query\"}","call_id":"call"}"#,
        "typed query"
      ),
      (
        "function_call_output", .toolResult, #"{"call_id":"call","output":"Visible tool result"}"#,
        "Visible tool result"
      ),
      (
        "error", .error,
        #"{"code":"unavailable","source":"execution","message":"Visible failure"}"#,
        "Visible failure"
      ),
      (
        "reasoning", .reasoning, #"{"summary":[{"type":"summary_text","text":"Visible summary"}]}"#,
        "Visible summary"
      ),
      (
        "compaction", .compaction,
        #"{"summary":"Visible compacted summary","token_count":120,"last_item_id":"anchor"}"#,
        "Visible compacted summary"
      ),
      (
        "slash_command", .command,
        #"{"name":"example:review","arguments":"current changes","output":"Reviewed changes"}"#,
        "/example:review current changes"
      ),
      (
        "routing_decision", .routing,
        #"{"model":"fixture-model","applied":true,"rationale":"Suitable for this task"}"#,
        "fixture-model"
      ),
      (
        "terminal_command", .terminal, #"{"kind":"input","input":"echo display-only"}"#,
        "echo display-only"
      ),
      (
        "web_search_call", .nativeTool, #"{"action":{"type":"search","query":"fixture search"}}"#,
        "fixture search"
      ),
      ("file_search_call", .nativeTool, #"{"queries":["fixture document"]}"#, "fixture document"),
      (
        "code_interpreter_call", .nativeTool,
        #"{"code":"print('display-only')","outputs":[{"type":"logs","logs":"display-only"}]}"#,
        "print('display-only')"
      ),
      ("computer_call", .nativeTool, #"{"action":{"type":"screenshot"}}"#, "screenshot"),
      (
        "image_generation_call", .nativeTool,
        #"{"revised_prompt":"A fixture landscape","result":"EMBEDDED_IMAGE_BYTES"}"#,
        "A fixture landscape"
      ),
      (
        "mcp_call", .nativeTool,
        #"{"name":"lookup","server_label":"fixture-server","arguments":"{\"query\":\"fixture MCP query\"}","output":"fixture MCP result"}"#,
        "fixture MCP query"
      ),
      (
        "mcp_list_tools", .nativeTool,
        #"{"server_label":"fixture-discovery","tools":[{"name":"fixture_lookup"}]}"#,
        "fixture-discovery"
      ),
    ]
    XCTAssertEqual(Set(fixtures.map { $0.0 }).count, 16)
    for (type, kind, fields, content) in fixtures {
      let message = try decode(type: type, fields: fields)
      XCTAssertEqual(message.id, "item-\(type)", type)
      XCTAssertEqual(message.responseID, "fixture-response", type)
      XCTAssertEqual(message.activity?.kind, kind, type)
      XCTAssertTrue(display(message).contains(content), "\(type) lost meaningful content")
      XCTAssertFalse(display(message).contains("preview not supported"), type)
      XCTAssertFalse(message.isStreaming, type)
      if kind != nil {
        XCTAssertEqual(message.activity?.status, type == "error" ? "failed" : "completed", type)
      }
    }
  }

  func testEveryNativeToolSurvivesWrapperWithoutBecomingUnknown() throws {
    for type in [
      "web_search_call", "file_search_call", "code_interpreter_call", "computer_call",
      "image_generation_call", "mcp_call", "mcp_list_tools",
    ] {
      let payload: [String: JSONValue] = [
        "id": .string("wrapper-\(type)"), "type": .string("native_tool"),
        "response_id": .string("response"),
        "item": .object([
          "type": .string(type), "status": .string("completed"), "call_id": .string("call"),
          "fixture_detail": .string("Visible provider detail"),
        ]),
      ]
      let message = try XCTUnwrap(ItemWire(payload: payload).message())
      XCTAssertEqual(message.activity?.kind, .nativeTool, type)
      XCTAssertEqual(message.activity?.status, "completed", type)
      XCTAssertEqual(message.callID, "call", type)
      XCTAssertTrue(display(message).contains("Visible provider detail"), type)
    }
  }

  func testToolCallsAndResultsKeepResponseAndCallIdentity() throws {
    for type in ["function_call", "function_call_output"] {
      let message = try decode(
        type: type,
        fields: #"{"call_id":"shared-call","name":"fixture","arguments":"{}","output":"result"}"#)
      XCTAssertEqual(message.callID, "shared-call")
      XCTAssertEqual(message.responseID, "fixture-response")
      XCTAssertEqual(message.id, "item-\(type)")
    }
  }

  func testRoutingDistinguishesAppliedFromSuggestion() throws {
    let applied = try decode(
      type: "routing_decision",
      fields: #"{"model":"fixture-model","applied":true,"rationale":"Applied rationale"}"#)
    let suggestion = try decode(
      type: "routing_decision",
      fields:
        #"{"model":"fixture-model","applied":false,"rationale":"Suggested rationale","agent":"child-agent"}"#
    )
    XCTAssertEqual(applied.activity?.title, "Using fixture-model")
    XCTAssertEqual(suggestion.activity?.title, "Would have picked fixture-model")
    XCTAssertTrue(display(suggestion).contains("child-agent"))
    XCTAssertTrue(display(suggestion).contains("Suggested rationale"))
  }

  func testSlashReceiptDefaultsToSkillAndPreservesInvocationAndOutput() throws {
    for kind in [nil, "skill", "command"] as [String?] {
      var fields = try object(
        #"{"name":"/fixture:review","arguments":"two files","output":"Receipt output"}"#)
      if let kind { fields["kind"] = .string(kind) }
      fields["id"] = .string("receipt")
      fields["type"] = .string("slash_command")
      let message = try XCTUnwrap(ItemWire(payload: fields).message())
      XCTAssertEqual(message.activity?.kind, .command)
      XCTAssertTrue(display(message).contains("/fixture:review two files"))
      XCTAssertTrue(display(message).contains("Receipt output"))
      XCTAssertTrue(
        message.activity?.title.hasPrefix(kind == "command" ? "Command" : "Skill") == true)
    }
  }

  func testTerminalInputAndOutputStayDistinctAndKeepBothStreams() throws {
    let input = try decode(
      type: "terminal_command", fields: #"{"kind":"input","input":"echo fixture"}"#)
    let output = try decode(
      type: "terminal_command",
      fields: #"{"kind":"output","stdout":"stdout fixture","stderr":"stderr fixture"}"#)
    XCTAssertEqual(input.activity?.title, "Terminal command")
    XCTAssertEqual(output.activity?.title, "Terminal output")
    XCTAssertEqual(output.activity?.details.map(\.title), ["Standard output", "Standard error"])
    XCTAssertTrue(display(output).contains("stdout fixture"))
    XCTAssertTrue(display(output).contains("stderr fixture"))
  }

  func testResourceReceiptsDistinguishCreateAndDeleteWithoutLosingIdentity() throws {
    let created = try decode(
      type: "resource_event",
      fields:
        #"{"event_type":"session.resource.created","resource_type":"terminal","resource_id":"term-1","resource":{"name":"Build terminal","id":"term-1","type":"terminal"}}"#
    )
    let deleted = try decode(
      type: "resource_event",
      fields:
        #"{"event_type":"session.resource.deleted","resource_type":"terminal","resource_id":"term-1"}"#
    )
    XCTAssertEqual(created.activity?.kind, .resource)
    XCTAssertEqual(created.activity?.title, "Terminal created")
    XCTAssertEqual(deleted.activity?.title, "Terminal deleted")
    XCTAssertTrue(display(created).contains("Build terminal"))
    XCTAssertTrue(display(created).contains("term-1"))
    XCTAssertTrue(display(deleted).contains("term-1"))
  }

  func testContextFilteringMatchesWholeLegacyNotificationNotLooseMarkers() throws {
    let hidden = [
      "This session is being continued from a previous conversation. Context follows.",
      "  <task-notification><task-id>task1</task-id><summary>Result</summary></task-notification>  ",
    ]
    for text in hidden {
      XCTAssertNil(try ItemWire(payload: messagePayload(text: text)).message(), text)
    }
    for text in [
      "Explain <task-notification> markup.",
      "<task-notification> this is an incomplete example",
      "The phrase This session is being continued from a previous conversation is quoted.",
    ] {
      XCTAssertEqual(try ItemWire(payload: messagePayload(text: text)).message()?.text, text)
    }
    var meta = messagePayload(text: "Private context")
    meta["is_meta"] = .bool(true)
    XCTAssertNil(try ItemWire(payload: meta).message())
  }

  func testHistoryAndLiveCommitUseSamePresentationForEveryKnownFamily() throws {
    let fixtures: [(String, String)] =
      [
        ("message", #"{"role":"assistant","content":"Final reply"}"#),
        ("function_call", #"{"name":"fixture","arguments":"{}","call_id":"call"}"#),
        ("function_call_output", #"{"output":"Final result","call_id":"call"}"#),
        ("error", #"{"code":"fixture_error","message":"Final failure"}"#),
        ("reasoning", #"{"summary":[{"type":"summary_text","text":"Final summary"}]}"#),
        ("compaction", #"{"summary":"Final compaction"}"#),
        ("slash_command", #"{"name":"fixture","arguments":"argument"}"#),
        ("routing_decision", #"{"model":"fixture","applied":false}"#),
        ("terminal_command", #"{"kind":"output","stdout":"Final output"}"#),
      ]
      + [
        "web_search_call", "file_search_call", "code_interpreter_call", "computer_call",
        "image_generation_call", "mcp_call", "mcp_list_tools",
      ].map { ($0, "{}") }
    for (type, fields) in fixtures {
      var payload = try object(fields)
      payload["id"] = .string("commit-\(type)")
      payload["type"] = .string(type)
      let expected = try XCTUnwrap(ItemWire(payload: payload).message())
      var reducer = makeReducer()
      let event: [String: JSONValue] = [
        "type": .string("response.output_item.done"), "item": .object(payload),
      ]
      _ = try reducer.apply(event)
      _ = try reducer.apply(event)
      XCTAssertEqual(reducer.snapshot.messages, [expected], type)
    }
  }

  func testLifecycleAliasesHaveSameTransitionsAndIgnoreStaleTerminalIDs() throws {
    for alias in [false, true] {
      func type(_ suffix: String) -> JSONValue {
        .string(alias ? "response.TaskStatus.\(suffix.uppercased())" : "response.\(suffix)")
      }
      for start in ["created", "queued", "in_progress"] {
        for end in ["completed", "failed", "incomplete", "cancelled"] {
          var reducer = makeReducer()
          _ = try reducer.apply(["type": type(start), "response": .object(["id": .string("new")])])
          XCTAssertEqual(reducer.snapshot.session.status, .running, "\(alias) \(start)")
          _ = try reducer.apply(
            try object(#"{"type":"response.output_text.delta","delta":"Partial text"}"#))
          _ = try reducer.apply(["type": type(end), "response": .object(["id": .string("old")])])
          XCTAssertEqual(reducer.snapshot.session.status, .running, "\(alias) stale \(end)")
          _ = try reducer.apply(["type": type(end), "response": .object(["id": .string("new")])])
          XCTAssertEqual(reducer.snapshot.session.status, .idle, "\(alias) \(end)")
          XCTAssertEqual(
            reducer.snapshot.messages.filter { $0.role == .assistant }.map(\.text), ["Partial text"]
          )
          XCTAssertFalse(reducer.snapshot.messages.contains(where: \.isStreaming))
        }
      }
    }
  }

  func testUsageSparseMergeReplacementAndResponseContextTokens() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(
      try object(
        #"{"type":"session.usage","conversation_id":"fixture-session","context_tokens":100,"context_window":1000,"total_cost_usd":0.5,"usage_by_model":{"model-a":{"input_tokens":10,"output_tokens":20}}}"#
      ))
    _ = try reducer.apply(
      try object(
        #"{"type":"session.usage","conversation_id":"fixture-session","total_cost_usd":0,"usage_by_model":{}}"#
      ))
    XCTAssertEqual(reducer.snapshot.eventState?.values["context_tokens"], .number(100))
    XCTAssertEqual(reducer.snapshot.eventState?.values["context_window"], .number(1000))
    XCTAssertEqual(reducer.snapshot.eventState?.values["total_cost_usd"], .number(0))
    XCTAssertEqual(reducer.snapshot.eventState?.values["usage_by_model"], .object([:]))
    _ = try reducer.apply(
      try object(
        #"{"type":"response.completed","response":{"id":"response","usage":{"input_tokens":400,"output_tokens":100,"total_tokens":500,"context_tokens":120}}}"#
      ))
    XCTAssertEqual(reducer.snapshot.eventState?.values["context_tokens"], .number(120))
    XCTAssertTrue(reducer.snapshot.messages.isEmpty)
    XCTAssertTrue(
      reducer.snapshot.eventState?.sections.contains(where: {
        $0.id == "usage" && $0.summary.contains("120")
      }) == true)
  }

  func testInvalidUsageNeverReplacesValidNonnegativeState() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(
      try object(
        #"{"type":"session.usage","conversation_id":"fixture-session","context_tokens":100,"context_window":1000,"total_cost_usd":0.5}"#
      ))
    for fields in [
      #"{"context_tokens":-1}"#, #"{"context_window":0}"#, #"{"total_cost_usd":-0.1}"#,
      #"{"context_tokens":"bad"}"#, #"{"context_window":null}"#,
    ] {
      var event = try object(fields)
      event["type"] = .string("session.usage")
      event["conversation_id"] = .string("fixture-session")
      _ = try reducer.apply(event)
      XCTAssertEqual(reducer.snapshot.eventState?.values["context_tokens"], .number(100), fields)
      XCTAssertEqual(reducer.snapshot.eventState?.values["context_window"], .number(1000), fields)
      XCTAssertEqual(reducer.snapshot.eventState?.values["total_cost_usd"], .number(0.5), fields)
    }
  }

  func testStatusBackgroundCountIsSparseAndExplicitZeroClears() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(
      try object(
        #"{"type":"session.status","conversation_id":"fixture-session","status":"waiting","background_task_count":2}"#
      ))
    _ = try reducer.apply(
      try object(
        #"{"type":"session.status","conversation_id":"fixture-session","status":"running"}"#))
    XCTAssertEqual(reducer.snapshot.eventState?.values["background_task_count"], .number(2))
    _ = try reducer.apply(
      try object(
        #"{"type":"session.status","conversation_id":"fixture-session","status":"idle","background_task_count":0}"#
      ))
    XCTAssertEqual(reducer.snapshot.eventState?.values["background_task_count"], .number(0))
    XCTAssertEqual(reducer.snapshot.eventState?.values["status"], .string("idle"))
    XCTAssertTrue(reducer.snapshot.messages.isEmpty)
  }

  func testTodosPresenceAndMCPReplacementListsClearOldEntries() throws {
    let fixtures: [(String, String, String, String)] = [
      (
        "session.todos", "todos",
        #"{"todos":[{"content":"Task","status":"in_progress","activeForm":"Working"}]}"#,
        #"{"todos":[]}"#
      ),
      (
        "session.presence", "viewers",
        #"{"viewers":[{"user_id":"fixture-viewer","joined_at":"2026-10-19T00:00:00Z","idle":true}]}"#,
        #"{"viewers":[]}"#
      ),
      (
        "session.mcp_startup", "mcp_startup", #"{"servers":{"fixture":{"status":"starting"}}}"#,
        #"{"servers":{}}"#
      ),
    ]
    for (type, key, populated, empty) in fixtures {
      var reducer = makeReducer()
      for fields in [populated, empty] {
        var event = try object(fields)
        event["type"] = .string(type)
        event["conversation_id"] = .string("fixture-session")
        let effects = try reducer.apply(event)
        XCTAssertTrue(effects.changed, type)
      }
      XCTAssertEqual(
        reducer.snapshot.eventState?.values[key], key == "mcp_startup" ? .object([:]) : .array([]),
        type)
      XCTAssertTrue(reducer.snapshot.messages.isEmpty, type)
    }
  }

  func testStartupTransitionsRetainFailuresAndClearTransientTerminalState() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(
      try object(
        #"{"type":"session.terminal_pending","conversation_id":"fixture-session","pending":true}"#))
    XCTAssertTrue(
      reducer.snapshot.eventState?.sections.contains(where: { $0.id == "terminal-pending" }) == true
    )
    _ = try reducer.apply(
      try object(
        #"{"type":"session.terminal_pending","conversation_id":"fixture-session","pending":false}"#)
    )
    XCTAssertFalse(
      reducer.snapshot.eventState?.sections.contains(where: { $0.id == "terminal-pending" }) == true
    )
    for stage in ["provisioning", "cloning", "starting", "connecting", "ready", "failed"] {
      _ = try reducer.apply([
        "type": .string("session.sandbox_status"), "conversation_id": .string("fixture-session"),
        "stage": .string(stage),
        "error": stage == "failed" ? .string("Fixture startup failed") : .null,
      ])
      XCTAssertEqual(
        reducer.snapshot.eventState?.values["sandbox_status"]?.object?["stage"], .string(stage))
    }
    XCTAssertTrue(
      reducer.snapshot.eventState?.sections.flatMap(\.details).contains(where: {
        $0.text.contains("Fixture startup failed")
      }) == true)
    for status in ["starting", "ready", "failed", "cancelled"] {
      _ = try reducer.apply([
        "type": .string("session.mcp_startup"), "conversation_id": .string("fixture-session"),
        "servers": .object(["fixture": .object(["status": .string(status)])]),
      ])
      XCTAssertEqual(
        reducer.snapshot.eventState?.values["mcp_startup"]?.object?["fixture"]?.object?["status"],
        .string(status))
    }
  }

  func testResourcesAreScopedAndDeletedFromActiveState() throws {
    var reducer = makeReducer()
    let create = try object(
      #"{"type":"session.resource.created","resource":{"id":"terminal-1","type":"terminal","name":"Build terminal","session_id":"fixture-session","metadata":{"cwd":"/fixture"}}}"#
    )
    _ = try reducer.apply(create)
    _ = try reducer.apply(create)
    XCTAssertEqual(reducer.snapshot.eventState?.values["resources"]?.object?.count, 1)
    _ = try reducer.apply(
      try object(
        #"{"type":"session.terminal.activity","session_id":"fixture-session","terminal_id":"terminal-1"}"#
      ))
    XCTAssertEqual(
      reducer.snapshot.eventState?.values["terminal_activity"]?.object?["terminal-1"], .bool(true))
    _ = try reducer.apply(
      try object(
        #"{"type":"session.resource.deleted","resource_id":"terminal-1","resource_type":"terminal","session_id":"other-session"}"#
      ))
    XCTAssertNotNil(reducer.snapshot.eventState?.values["resources"]?.object?["terminal-1"])
    _ = try reducer.apply(
      try object(
        #"{"type":"session.resource.deleted","resource_id":"terminal-1","resource_type":"terminal","session_id":"fixture-session"}"#
      ))
    XCTAssertNil(reducer.snapshot.eventState?.values["resources"]?.object?["terminal-1"])
    XCTAssertFalse(
      reducer.snapshot.eventState?.sections.contains(where: { $0.id == "resource-terminal-1" })
        == true)
  }

  func testChildUpdatesMergeAndSupersessionKeepsSourceConversation() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(
      try object(
        #"{"type":"session.created","conversation_id":"fixture-session","child_session_id":"child-1","agent_id":"agent-1","parent_session_id":"fixture-session"}"#
      ))
    _ = try reducer.apply(
      try object(
        #"{"type":"session.child_session.updated","conversation_id":"fixture-session","child_session_id":"child-1","child":{"title":"Child task","status":"running"}}"#
      ))
    _ = try reducer.apply(
      try object(
        #"{"type":"session.child_session.updated","conversation_id":"fixture-session","child_session_id":"child-1","child":{"status":"idle","preview":"Child finished"}}"#
      ))
    XCTAssertEqual(
      reducer.snapshot.eventState?.values["children"]?.object?["child-1"]?.object?["title"],
      .string("Child task"))
    XCTAssertEqual(
      reducer.snapshot.eventState?.values["children"]?.object?["child-1"]?.object?["status"],
      .string("idle"))
    _ = try reducer.apply(
      try object(
        #"{"type":"session.superseded","conversation_id":"fixture-session","target_conversation_id":"replacement-session"}"#
      ))
    XCTAssertEqual(reducer.snapshot.id, "fixture-session")
    XCTAssertEqual(reducer.snapshot.eventState?.supersededSessionID, "replacement-session")
    XCTAssertTrue(
      reducer.snapshot.eventState?.sections.contains(where: {
        $0.id == "superseded" && $0.sessionID == "replacement-session"
      }) == true)
  }

  func testCatalogSkillsAndChangedFilesInvalidateWithoutInventedTranscript() throws {
    var reducer = makeReducer()
    for type in ["session.skills", "session.model_options", "session.agent_changed"] {
      let effects = try reducer.apply([
        "type": .string(type), "conversation_id": .string("fixture-session"),
        "agent_id": .string("new-agent"), "agent_name": .string("New agent"),
      ])
      XCTAssertTrue(effects.reconcile, type)
      XCTAssertTrue(reducer.snapshot.messages.isEmpty, type)
    }
    _ = try reducer.apply(
      try object(
        #"{"type":"session.collaboration_mode","conversation_id":"fixture-session","mode":"plan"}"#)
    )
    XCTAssertEqual(reducer.snapshot.eventState?.values["collaboration_mode"], .string("plan"))
    let files = try reducer.apply(
      try object(
        #"{"type":"session.changed_files.invalidated","session_id":"fixture-session","environment_id":"local"}"#
      ))
    XCTAssertEqual(files.changedFilesEnvironment, "local")
    XCTAssertNotNil(reducer.snapshot.eventState?.values["changed_files"]?.object?["local"])
    let defaultFiles = try reducer.apply(
      try object(#"{"type":"session.changed_files.invalidated","session_id":"fixture-session"}"#))
    XCTAssertEqual(defaultFiles.changedFilesEnvironment, "default")
    XCTAssertTrue(reducer.snapshot.messages.isEmpty)
  }

  func testSessionEventsFromOtherConversationCannotMutateSnapshot() throws {
    let events = [
      #"{"type":"session.usage","context_tokens":100}"#,
      #"{"type":"session.todos","todos":[]}"#,
      #"{"type":"session.presence","viewers":[]}"#,
      #"{"type":"session.terminal_pending","pending":true}"#,
      #"{"type":"session.sandbox_status","stage":"failed","error":"Other failure"}"#,
      #"{"type":"session.mcp_startup","servers":{}}"#,
      #"{"type":"session.collaboration_mode","mode":"plan"}"#,
      #"{"type":"session.created","child_session_id":"other-child"}"#,
      #"{"type":"session.superseded","target_conversation_id":"other-replacement"}"#,
      #"{"type":"session.child_session.updated","child_session_id":"other-child","child":{"status":"running"}}"#,
      #"{"type":"session.status","status":"running"}"#,
      #"{"type":"session.skills"}"#,
      #"{"type":"session.model_options"}"#,
      #"{"type":"session.agent_changed","agent_id":"other-agent","agent_name":"Other"}"#,
    ]
    for json in events {
      var reducer = makeReducer()
      let before = reducer.snapshot
      var event = try object(json)
      event["conversation_id"] = .string("other-session")
      let effects = try reducer.apply(event)
      XCTAssertFalse(effects.changed, json)
      XCTAssertFalse(effects.reconcile, json)
      XCTAssertEqual(reducer.snapshot, before, json)
    }
    for json in [
      #"{"type":"session.resource.created","resource":{"id":"other-resource","type":"terminal","name":"Other","session_id":"other-session","metadata":{}}}"#,
      #"{"type":"session.changed_files.invalidated","session_id":"other-session","environment_id":"other-environment"}"#,
      #"{"type":"session.terminal.activity","session_id":"other-session","terminal_id":"other-terminal"}"#,
    ] {
      var reducer = makeReducer()
      let before = reducer.snapshot
      let effects = try reducer.apply(try object(json))
      XCTAssertFalse(effects.changed, json)
      XCTAssertEqual(reducer.snapshot, before, json)
    }
  }

  func testTransportHeartbeatsNeverCreateTranscriptOrEndResponse() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(try object(#"{"type":"response.created","response":{"id":"active"}}"#))
    for type in ["response.heartbeat", "session.heartbeat"] {
      let effects = try reducer.apply(["type": .string(type)])
      XCTAssertFalse(effects.changed)
      XCTAssertFalse(effects.reconcile)
      XCTAssertTrue(reducer.snapshot.messages.isEmpty)
      XCTAssertEqual(reducer.snapshot.session.status, .running)
    }
  }

  func testElicitationResolutionRequiresExactIDAndToolOutputCannotResolveIt() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(
      try object(
        #"{"type":"response.elicitation_request","elicitation_id":"approval-1","params":{"target_session_id":"child-1","message":"Approve fixture?"}}"#
      ))
    XCTAssertEqual(reducer.snapshot.pendingDecisions.first?.targetSessionID, "child-1")
    _ = try reducer.apply(
      try object(
        #"{"type":"response.output_item.done","item":{"id":"tool-result","type":"function_call_output","call_id":"approval-1","output":"Completed"}}"#
      ))
    XCTAssertEqual(reducer.snapshot.pendingDecisions.map(\.id), ["approval-1"])
    _ = try reducer.apply(
      try object(#"{"type":"response.elicitation_resolved","elicitation_id":"unrelated"}"#))
    XCTAssertEqual(reducer.snapshot.pendingDecisions.map(\.id), ["approval-1"])
    XCTAssertEqual(reducer.snapshot.session.status, .needsResponse)
    _ = try reducer.apply(
      try object(#"{"type":"response.elicitation_resolved","elicitation_id":"approval-1"}"#))
    XCTAssertTrue(reducer.snapshot.pendingDecisions.isEmpty)
  }

  func testUnsupportedSchemaAndIncompleteURLModeCannotBecomeBinaryApproval() throws {
    for params in [
      #"{"message":"Array form","requestedSchema":{"type":"array","items":{"type":"string"}}}"#,
      #"{"message":"Union form","requestedSchema":{"oneOf":[{"type":"string"},{"type":"number"}]}}"#,
      #"{"message":"URL confirmation","mode":"url"}"#,
    ] {
      let wire = try ElicitationWire(
        value: .object([
          "elicitation_id": .string("unsupported"), "params": .object(try object(params)),
        ]), sessionID: "fixture-session")
      XCTAssertNotNil(wire.decision.unsupportedReason, params)
    }
  }

  func testDisplayOnlyEventsHaveMeaningfulTypedActivity() throws {
    let events: [(ConversationActivity.Kind, String, String)] = [
      (
        .file,
        #"{"type":"response.output_file.done","file_id":"file-1","filename":"fixture.txt","content_type":"text/plain"}"#,
        "fixture.txt"
      ),
      (
        .retry,
        #"{"type":"response.retry","source":"provider","attempt":2,"max_attempts":4,"delay_seconds":0.5,"error":{"code":"busy","message":"Fixture retry"}}"#,
        "Fixture retry"
      ),
      (
        .error,
        #"{"type":"response.error","source":"provider","error":{"code":"fixture_failure","message":"Fixture failure"}}"#,
        "Fixture failure"
      ),
      (
        .clientTask,
        #"{"type":"response.client_task.cancel","task_id":"fixture-task","call_id":"fixture-call"}"#,
        "fixture-task"
      ),
      (
        .browser,
        #"{"type":"browser.action_request","action_id":"fixture-browser","action":"navigate","args":{"url":"https://example.invalid/fixture"}}"#,
        "navigate"
      ),
      (
        .policy,
        #"{"type":"response.policy_denied","phase":"input","reason":"Fixture policy denial"}"#,
        "Fixture policy denial"
      ),
    ]
    for (kind, json, content) in events {
      var reducer = makeReducer()
      _ = try reducer.apply(try object(json))
      let message = try XCTUnwrap(
        reducer.snapshot.messages.first { $0.activity?.kind == kind }, json)
      XCTAssertTrue(display(message).contains(content), json)
      XCTAssertFalse(message.isStreaming, json)
      XCTAssertTrue(reducer.snapshot.pendingDecisions.isEmpty, json)
    }
  }

  func testCompactionCompletesOrFailsWithoutChangingTranscriptMeaning() throws {
    for outcome in ["completed", "failed"] {
      var reducer = makeReducer()
      reducer.snapshot.messages = [
        ConversationMessage(id: "before", role: .user, text: "Question before compaction")
      ]
      _ = try reducer.apply(try object(#"{"type":"response.compaction.in_progress"}"#))
      XCTAssertTrue(
        reducer.snapshot.messages.contains { $0.activity?.kind == .compaction && $0.isStreaming })
      _ = try reducer.apply([
        "type": .string("response.compaction.\(outcome)"), "total_tokens": .number(84),
        "error": .string("Compaction fixture failed"),
      ])
      XCTAssertEqual(
        reducer.snapshot.messages.filter { $0.role == .user }.map(\.text),
        ["Question before compaction"])
      let activities = reducer.snapshot.messages.filter { $0.activity?.kind == .compaction }
      XCTAssertEqual(activities.count, 1)
      XCTAssertFalse(activities.contains(where: \.isStreaming))
      if outcome == "completed" {
        XCTAssertEqual(reducer.snapshot.eventState?.values["context_tokens"], .number(84))
      } else {
        XCTAssertNil(reducer.snapshot.eventState?.values["context_tokens"])
        XCTAssertTrue(display(try XCTUnwrap(activities.first)).lowercased().contains("fail"))
      }
    }
  }

  func testToolOutputStreamsThenFinalCommitReplacesPreviewAndReplayDoesNotDuplicate() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(try object(#"{"type":"response.created","response":{"id":"turn-1"}}"#))
    _ = try reducer.apply(
      try object(
        #"{"type":"response.output_item.done","item":{"id":"call-1","type":"function_call","call_id":"tool-1","response_id":"turn-1","name":"fixture-tool","arguments":"{}"}}"#
      ))
    for delta in ["Partial ", "output"] {
      _ = try reducer.apply([
        "type": .string("response.function_call_output.delta"), "call_id": .string("tool-1"),
        "delta": .string(delta),
      ])
    }
    let preview = try XCTUnwrap(
      reducer.snapshot.messages.first { $0.activity?.kind == .toolResult })
    XCTAssertTrue(display(preview).contains("Partial output"))
    XCTAssertTrue(preview.isStreaming)
    let final = try object(
      #"{"type":"response.output_item.done","item":{"id":"result-1","type":"function_call_output","call_id":"tool-1","response_id":"turn-1","output":"Partial output completed"}}"#
    )
    _ = try reducer.apply(final)
    _ = try reducer.apply(final)
    let results = reducer.snapshot.messages.filter { $0.activity?.kind == .toolResult }
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?.id, "result-1")
    XCTAssertTrue(display(try XCTUnwrap(results.first)).contains("Partial output completed"))
    XCTAssertFalse(results.first?.isStreaming ?? true)
  }

  func testReasoningSummaryInterleavesWithTextAndCommitRetiresOnlyMatchingActivity() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(try object(#"{"type":"response.created","response":{"id":"turn-1"}}"#))
    _ = try reducer.apply(
      try object(#"{"type":"response.output_text.delta","delta":"Before reasoning"}"#))
    _ = try reducer.apply(try object(#"{"type":"response.reasoning.started"}"#))
    _ = try reducer.apply(
      try object(#"{"type":"response.reasoning_text.delta","delta":"PRIVATE_RAW_REASONING"}"#))
    _ = try reducer.apply(
      try object(#"{"type":"response.reasoning_summary_text.delta","delta":"Visible summary"}"#))
    _ = try reducer.apply(
      try object(
        #"{"type":"response.output_item.done","item":{"id":"reasoning-1","type":"reasoning","response_id":"turn-1","summary":[{"type":"summary_text","text":"Visible summary"}]}}"#
      ))
    _ = try reducer.apply(
      try object(#"{"type":"response.output_text.delta","delta":"After reasoning"}"#))
    XCTAssertEqual(
      reducer.snapshot.messages.filter { $0.role == .assistant }.map(\.text),
      ["Before reasoning", "After reasoning"])
    let summaries = reducer.snapshot.messages.filter { $0.activity?.kind == .reasoning }
    XCTAssertEqual(summaries.count, 1)
    XCTAssertEqual(summaries.first?.id, "reasoning-1")
    XCTAssertTrue(display(try XCTUnwrap(summaries.first)).contains("Visible summary"))
    XCTAssertFalse(
      reducer.snapshot.messages.map(display).joined().contains("PRIVATE_RAW_REASONING"))
  }

  func testNestedInterruptionSealsOnlyTheMatchingLiveTurn() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(try object(#"{"type":"response.created","response":{"id":"active"}}"#))
    _ = try reducer.apply(
      try object(#"{"type":"response.output_text.delta","delta":"Partial reply"}"#))
    _ = try reducer.apply(
      try object(#"{"type":"session.interrupted","data":{"response_id":"old"}}"#))
    XCTAssertEqual(reducer.snapshot.session.status, .running)
    _ = try reducer.apply(
      try object(#"{"type":"session.interrupted","data":{"response_id":"active"}}"#))
    XCTAssertEqual(reducer.snapshot.session.status, .idle)
    XCTAssertEqual(
      reducer.snapshot.messages.filter { $0.role == .assistant }.map(\.text), ["Partial reply"])
    XCTAssertFalse(reducer.snapshot.messages.contains(where: \.isStreaming))
  }

  func testUnknownLiveEventsHaveBoundedInspectableSafeFallback() throws {
    var reducer = makeReducer()
    _ = try reducer.apply([
      "type": .string("response.future_activity"), "id": .string("future-event"),
      "message": .string("Useful future activity"),
      "payload": .object([
        "text": .string(String(repeating: "visible fixture text ", count: 20_000)),
        "api_key": .string("PRIVATE_CREDENTIAL"),
        "encrypted_content": .string("PRIVATE_HIDDEN_DATA"),
      ]),
    ])
    let message = try XCTUnwrap(reducer.snapshot.messages.first)
    XCTAssertEqual(message.activity?.kind, .unknown)
    let content = display(message)
    XCTAssertTrue(content.contains("Useful future activity"))
    XCTAssertLessThan(content.count, 50_000)
    XCTAssertFalse(content.contains("PRIVATE_"))
  }

  private func decode(type: String, fields: String) throws -> ConversationMessage {
    var payload = try object(fields)
    payload["id"] = .string("item-\(type)")
    payload["type"] = .string(type)
    payload["response_id"] = .string("fixture-response")
    payload["status"] = .string("completed")
    return try XCTUnwrap(ItemWire(payload: payload).message())
  }

  private func object(_ json: String) throws -> [String: JSONValue] {
    try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)).object)
  }

  private func display(_ message: ConversationMessage) -> String {
    ([message.text, message.activity?.title ?? "", message.activity?.summary ?? ""]
      + (message.activity?.details.map(\.text) ?? [])).joined(separator: "\n")
  }

  private func messagePayload(text: String) -> [String: JSONValue] {
    [
      "id": .string("context"), "type": .string("message"), "role": .string("user"),
      "content": .string(text),
    ]
  }

  private func makeReducer() -> LiveConversationReducer {
    LiveConversationReducer(
      snapshot: ConversationSnapshot(
        revision: 1, session: SessionSummary(id: "fixture-session", title: "Fixture", preview: ""),
        messages: []))
  }
}
