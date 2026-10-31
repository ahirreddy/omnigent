import Foundation

extension LiveConversationReducer {
  mutating func applyPresentationEvent(_ event: [String: JSONValue], type: String) throws
    -> LiveEventEffects?
  {
    var effects = LiveEventEffects()
    var state = snapshot.eventState ?? SessionEventState()
    switch type {
    case "session.heartbeat", "response.heartbeat": return effects
    case "session.usage":
      for key in ["context_tokens", "context_window", "total_cost_usd", "usage_by_model"] {
        guard let value = event[key], value != .null else { continue }
        if key == "usage_by_model" {
          guard let models = value.object,
            models.values.allSatisfy({ bucket in
              guard let fields = bucket.object else { return false }
              return fields.values.allSatisfy { $0 == .null || $0.nonnegativeNumber != nil }
            })
          else { return effects }
        } else if value.nonnegativeNumber == nil
          || (key == "context_window" && value.nonnegativeNumber == 0)
        {
          return effects
        }
      }
      for key in ["context_tokens", "context_window", "total_cost_usd", "usage_by_model"] {
        if let value = event[key], value != .null { state.set(key, value) }
      }
    case "session.todos":
      guard let todos = event["todos"]?.array else { return effects }
      state.set(
        "todos",
        .array(
          todos.filter {
            guard let task = $0.object else { return false }
            return task["content"]?.string != nil
              && ["pending", "in_progress", "completed"].contains(task["status"]?.string ?? "")
          }))
    case "session.presence":
      guard let viewers = event["viewers"]?.array,
        viewers.allSatisfy({ $0.object?["user_id"]?.string != nil })
      else { return effects }
      state.set("viewers", .array(viewers))
    case "session.mcp_startup":
      guard let servers = event["servers"]?.object else { return effects }
      state.set(
        "mcp_startup",
        .object(
          servers.filter { _, value in
            ["starting", "ready", "failed", "cancelled"].contains(
              value.object?["status"]?.string ?? "")
          }))
    case "session.terminal_pending":
      state.set("terminal_pending", .bool(event["pending"]?.bool == true))
    case "session.sandbox_status":
      guard let stage = event["stage"]?.string,
        ["provisioning", "cloning", "starting", "connecting", "ready", "failed"].contains(stage)
      else { return effects }
      state.set(
        "sandbox_status", .object(["stage": .string(stage), "error": event["error"] ?? .null]))
    case "session.collaboration_mode":
      guard let mode = event["mode"]?.string else { return effects }
      state.set("collaboration_mode", .string(mode))
    case "session.resource.created":
      guard let resource = event["resource"]?.object, let id = resource["id"]?.string,
        resource["session_id"]?.string == nil || resource["session_id"]?.string == snapshot.id
      else { return effects }
      state.updateRecord("resources", id: id, value: .object(resource))
      effects.reconcile = true
    case "session.resource.deleted":
      guard let id = event["resource_id"]?.string else { return effects }
      state.updateRecord("resources", id: id, value: nil)
      state.updateRecord("terminal_activity", id: id, value: nil)
      effects.reconcile = true
    case "session.terminal.activity":
      guard let id = event["terminal_id"]?.string else { return effects }
      state.updateRecord("terminal_activity", id: id, value: .bool(true))
    case "session.created", "session.child_session.updated":
      guard let id = event["child_session_id"]?.string, !id.isEmpty else { return effects }
      var child = state.values["children"]?.object?[id]?.object ?? [:]
      let update =
        event["child"]?.object ?? [
          "status": .string("Created"), "agent_name": event["agent_id"] ?? .string("Subagent"),
        ]
      child.merge(update) { _, new in new }
      state.updateRecord("children", id: id, value: .object(child))
    case "session.superseded":
      guard let target = event["target_conversation_id"]?.string, !target.isEmpty else {
        return effects
      }
      state.set("superseded", .string(target))
      effects.reconcile = true
    case "session.skills": effects.reconcile = true
    case "session.changed_files.invalidated":
      let environment = event["environment_id"]?.string ?? "default"
      guard !environment.isEmpty else { return effects }
      state.updateRecord(
        "changed_files", id: environment,
        value: .object(["error": .string("Loading changed files…")]))
      effects.changedFilesEnvironment = environment
    case "response.function_call_output.delta":
      guard acceptsResponseDeltas, let call = event["call_id"]?.string, !call.isEmpty,
        let delta = event["delta"]?.string
      else { return effects }
      let id = "live:tool:\(responseID ?? snapshot.id):\(call)"
      guard !retiredActivityIDs.contains(id) else { return effects }
      guard acceptsChunk(event, key: id) else { return effects }
      // A late replay must not resurrect output already committed to history.
      if snapshot.messages.contains(where: {
        !isEphemeral($0) && $0.callID == call && $0.activity?.kind == .toolResult
          && $0.responseID == responseID
      }) {
        return effects
      }
      let output = String(((activityBuffers[id] ?? "") + delta).prefix(65_536))
      activityBuffers[id] = output
      upsertActivity(
        id: id, kind: .toolResult, title: "Tool output", summary: "Receiving output…",
        status: "in_progress",
        details: [
          .init(
            id: "output", title: "Output", text: JSONValue.string(output).safeDisplayText,
            isCode: true)
        ], callID: call, streaming: true)
    case "response.reasoning.started", "response.reasoning_text.delta",
      "response.reasoning_summary_text.delta":
      guard acceptsResponseDeltas else { return effects }
      let sourceID = event["item_id"]?.string ?? event["message_id"]?.string
      let id =
        sourceID.map { "live:reasoning:\(responseID ?? snapshot.id):item:\($0)" }
        ?? activeReasoningID ?? "live:reasoning:\(responseID ?? snapshot.id):\(activitySequence)"
      if let sourceID, snapshot.messages.contains(where: { $0.id == sourceID }) { return effects }
      guard !retiredActivityIDs.contains(id), acceptsChunk(event, key: "\(id):\(type)") else {
        return effects
      }
      if activeReasoningID != id {
        closeReasoningSection()
        closeTextSection()
        activeReasoningID = id
      }
      if let sourceID { activityItemIDs[id] = sourceID }
      // Raw/private reasoning is never substituted for an explicitly exposed summary.
      var summary = activityBuffers[id] ?? ""
      if type == "response.reasoning_summary_text.delta" {
        guard let delta = event["delta"]?.string else { return effects }
        summary = String((summary + delta).prefix(16_000))
      } else if type == "response.reasoning.started", !summary.isEmpty, !summary.hasSuffix("\n\n") {
        summary += "\n\n"
      }
      activityBuffers[id] = summary
      upsertActivity(
        id: id, kind: .reasoning, title: "Reasoning",
        summary: summary.isEmpty ? "Working…" : String(summary.prefix(180)),
        status: "in_progress",
        details: summary.isEmpty ? [] : [.init(id: "summary", title: "Summary", text: summary)],
        streaming: true)
    case "response.output_file.done":
      guard let fileID = event["file_id"]?.string, !fileID.isEmpty else { return effects }
      let title = event["filename"]?.string ?? "Generated file"
      let id = "event:file:\(fileID)"
      upsertActivity(id: id, kind: .file, title: "File ready", summary: title, status: "completed")
      if let index = snapshot.messages.firstIndex(where: { $0.id == id }) {
        snapshot.messages[index].attachments = [
          .init(
            id: fileID, kind: .file, title: title,
            reference: fileID, mimeType: event["content_type"]?.string)
        ]
      }
    case "response.retry":
      let attempt = event["attempt"]?.int ?? 0
      let max = event["max_attempts"]?.int ?? 0
      let delay = event["delay_seconds"]?.nonnegativeNumber ?? 0
      let summary = "Attempt \(attempt) of \(max) · retry in \(delay) seconds"
      upsertActivity(
        id:
          "event:retry:\(responseID ?? snapshot.id):\(event["tool_name"]?.string ?? "model"):\(attempt)",
        kind: .retry, title: "Retrying \(event["tool_name"]?.string ?? "response")",
        summary: summary,
        status: "retrying",
        details: [
          .init(
            id: "error", title: "Cause",
            text: event["error"]?.safeDisplayText ?? "No details reported")
        ])
    case "response.error":
      let error = event["error"] ?? .object(["message": .string("An error occurred.")])
      let message = error.object?["message"]?.string ?? error.string ?? "An error occurred."
      presentError(error, source: event["source"]?.string)
      effects.error = message
      snapshot.session.failureMessage = message
    case "response.policy_denied":
      let reason = event["reason"]?.safeDisplayText ?? "The server declined this action."
      upsertActivity(
        id: "event:policy:\(responseID ?? snapshot.id):\(stableFingerprint(reason))",
        kind: .policy, title: "Action declined by policy", summary: reason, status: "denied",
        details: [.init(id: "phase", title: "Phase", text: event["phase"]?.safeDisplayText ?? "")])
      snapshot.session.failureMessage = reason
      effects.error = reason
      effects.reconcile = true
    case "response.compaction.in_progress", "response.compaction.completed",
      "response.compaction.failed":
      let progress = type.hasSuffix("in_progress")
      let failed = type.hasSuffix("failed")
      if !progress, !failed, let tokens = event["total_tokens"], tokens.nonnegativeNumber != nil {
        state.set("context_tokens", tokens)
      }
      upsertActivity(
        id: "event:compaction:\(responseID ?? snapshot.id)", kind: .compaction,
        title: progress
          ? "Compacting context" : (failed ? "Compaction failed" : "Context compacted"),
        summary: failed
          ? "History is unchanged."
          : (progress ? "Summarizing earlier context…" : "Earlier context was summarized."),
        status: progress ? "in_progress" : (failed ? "failed" : "completed"),
        details: failed
          ? [
            .init(
              id: "error", title: "Error",
              text: event["error"]?.safeDisplayText ?? "Compaction failed.")
          ] : [],
        streaming: progress)
      if !progress { effects.reconcile = true }
    case "response.client_task.cancel":
      guard let id = event["task_id"]?.string, !id.isEmpty else { return effects }
      upsertActivity(
        id: "event:client:\(id)", kind: .clientTask, title: "Client task cancelled",
        summary: "The server cancelled this client-side task.", status: "cancelled",
        details: [.init(id: "task", title: "Task ID", text: id)], callID: event["call_id"]?.string)
    case "browser.action_request":
      guard let id = event["action_id"]?.string, let action = event["action"]?.string else {
        return effects
      }
      upsertActivity(
        id: "event:browser:\(id)", kind: .browser, title: "Desktop browser: \(action)",
        summary:
          "Waiting for the connected desktop browser. This phone does not execute browser-agent actions.",
        status: "desktop_required",
        details: [
          .init(id: "request", title: "Request", text: event["args"]?.safeDisplayText ?? "")
        ])
    default: return nil
    }
    snapshot.eventState = state
    effects.changed = true
    return effects
  }

  mutating func observeLifecycle(_ event: [String: JSONValue], type: String) {
    var state = snapshot.eventState ?? SessionEventState()
    if type == "session.status" {
      state.set("status", event["status"])
      if let count = event["background_task_count"], count.nonnegativeNumber != nil {
        state.set("background_task_count", count)
      }
    }
    if ["response.created", "response.queued", "response.in_progress", "response.started"].contains(
      type)
    {
      state.set("status", .string(type.hasSuffix("queued") ? "queued" : "running"))
    }
    if [
      "response.completed", "response.failed", "response.incomplete", "response.cancelled",
      "session.interrupted",
    ].contains(type) {
      let response = event["response"]?.object ?? event["data"]?.object ?? event
      if let id = response["id"]?.string ?? response["response_id"]?.string, let responseID,
        id != responseID
      {
        return
      }
      state.set("status", .string(type.split(separator: ".").last.map(String.init) ?? "idle"))
      if let usage = response["usage"]?.object {
        let tokens = usage["context_tokens"] ?? usage["total_tokens"]
        if let tokens, tokens.nonnegativeNumber != nil { state.set("context_tokens", tokens) }
      }
      if let cost = response["total_cost_usd"], cost.nonnegativeNumber != nil {
        state.set("total_cost_usd", cost)
      }
      if let models = response["usage_by_model"]?.object,
        models.values.allSatisfy({ bucket in
          bucket.object?.values.allSatisfy { $0 == .null || $0.nonnegativeNumber != nil } == true
        })
      {
        state.set("usage_by_model", .object(models))
      }
    }
    snapshot.eventState = state
  }

  mutating func upsertActivity(
    id: String, kind: ConversationActivity.Kind, title: String, summary: String,
    status: String? = nil, details: [ConversationDetailSection] = [], callID: String? = nil,
    streaming: Bool = false
  ) {
    let title = title.boundedDisplay(200)
    let summary = summary.boundedDisplay()
    let activity = ConversationActivity(
      kind: kind, title: title, summary: summary, status: status, details: details)
    var message = ConversationMessage(
      id: id, role: .tool, text: "\(title)\n\(summary)", isStreaming: streaming,
      activity: activity, callID: callID, responseID: responseID)
    if let index = snapshot.messages.firstIndex(where: { $0.id == id }) {
      message.attachments = snapshot.messages[index].attachments
      snapshot.messages[index] = message
    } else {
      snapshot.messages.append(message)
    }
  }

  mutating func acceptsChunk(_ event: [String: JSONValue], key: String) -> Bool {
    guard let value = event["index"] else { return true }
    guard let index = value.validChunkIndex else { return false }
    if let previous = activityIndices[key], index <= previous { return false }
    activityIndices[key] = index
    return true
  }

  mutating func presentUnknownEvent(_ event: [String: JSONValue], type: String) -> LiveEventEffects
  {
    let text = JSONValue.object(event).safeDisplayText
    let id = "event:unknown:\(responseID ?? snapshot.id):\(type):\(stableFingerprint(text))"
    if let itemID = event["item_id"]?.string ?? event["id"]?.string { activityItemIDs[id] = itemID }
    if let itemID = activityItemIDs[id], snapshot.messages.contains(where: { $0.id == itemID }) {
      return LiveEventEffects()
    }
    upsertActivity(
      id: id, kind: .unknown, title: "Session event",
      summary: type,
      details: [.init(id: "payload", title: "Event details", text: text, isCode: true)])
    let unknownIDs = snapshot.messages.filter { $0.id.hasPrefix("event:unknown:") }.map(\.id)
    if unknownIDs.count > 80 { snapshot.messages.removeAll { $0.id == unknownIDs.first } }
    return LiveEventEffects(changed: true)
  }

  mutating func presentError(_ value: JSONValue, source: String?) {
    let error = value.object ?? [:]
    let message = error["message"]?.string ?? value.string ?? "An error occurred."
    let code = error["code"]?.string
    let id =
      "event:error:\(responseID ?? snapshot.id):\(code ?? "unknown"):\(stableFingerprint(message))"
    var details = [
      ConversationDetailSection(id: "message", title: "Error", text: message.boundedDisplay(16_000))
    ]
    if let code {
      details.append(.init(id: "code", title: "Code", text: code.boundedDisplay(200), isCode: true))
    }
    if let source {
      details.append(.init(id: "source", title: "Source", text: source.boundedDisplay(200)))
    }
    let preview = ConversationMessage(
      id: id, role: .tool, text: message,
      activity: .init(
        kind: .error, title: "Response error", summary: message.boundedDisplay(), status: "failed",
        details: details),
      responseID: responseID)
    if snapshot.messages.contains(where: { !isEphemeral($0) && matchesActivity(preview, $0) }) {
      return
    }
    upsertActivity(
      id: id, kind: .error, title: "Response error", summary: message, status: "failed",
      details: details)
  }

  func stableFingerprint(_ text: String) -> UInt64 {
    text.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
  }
}

extension JSONValue {
  var nonnegativeNumber: Double? {
    guard case .number(let value) = self, value.isFinite, value >= 0 else { return nil }
    return value
  }

  var validChunkIndex: Int? {
    guard let value = nonnegativeNumber, value == value.rounded() else { return nil }
    return int
  }
}
