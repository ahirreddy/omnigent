import Foundation

struct LiveEventEffects {
  var changed = false
  var reconcile = false
  var consumedItemID: String?
  var consumedPendingID: String?
  var error: String?
  var changedFilesEnvironment: String?
}

/// Reconciles live previews with authoritative item IDs; replayed native chunks use indices.
struct LiveConversationReducer {
  var snapshot: ConversationSnapshot
  var responseID: String?
  var segment = 0
  private var nativeIndices: [String: Int] = [:]
  private var retiredNativeMessages: Set<String> = []
  var activitySequence = 0
  var activityIndices: [String: Int] = [:]
  var activityBuffers: [String: String] = [:]
  var activeReasoningID: String?
  var activityItemIDs: [String: String] = [:]
  var retiredActivityIDs: Set<String> = []
  var endedResponseIDs: Set<String> = []
  var acceptsResponseDeltas = true
  private var acceptsNativeDeltas = true
  var resolvedDecisionIDs: Set<String> = []

  init(snapshot: ConversationSnapshot) {
    self.snapshot = snapshot
    self.snapshot.messages.removeAll { $0.id.hasPrefix("live:") }
    resolvedDecisionIDs = Set(snapshot.decisions.filter { $0.response != nil }.map(\.id))
  }

  mutating func reconcile(with authoritative: ConversationSnapshot) {
    let previousMessages = snapshot.messages
    let previousStatus = snapshot.session.status
    let previousCommittedIDs = Set(previousMessages.filter { !$0.id.hasPrefix("live:") }.map(\.id))
    var previews = previousMessages.filter { isEphemeral($0) }
    var replacementAnchors: [String: String] = [:]
    var staleTextIDs: Set<String> = []
    // Each persisted item retires at most one matching preview, including stopped partial text.
    for message in authoritative.messages {
      if let index = previews.firstIndex(where: {
        $0.id == message.id || matchesActivity($0, message)
          || (!previousCommittedIDs.contains(message.id) && matchesText($0, message))
      }) {
        let preview = previews[index]
        // A history read can finish with an older prefix while SSE has already advanced.
        if preview.isStreaming, preview.activity == nil,
          preview.text.count > message.text.count, preview.text.hasPrefix(message.text)
        {
          staleTextIDs.insert(message.id)
          continue
        }
        previews.remove(at: index)
        replacementAnchors[preview.id] = message.id
        retirePreview(preview)
      }
    }
    var eventState = snapshot.eventState ?? SessionEventState()
    eventState.merge(authoritative.eventState)
    snapshot = authoritative
    snapshot.messages.removeAll { staleTextIDs.contains($0.id) }
    snapshot.eventState = eventState
    snapshot.decisions.removeAll { resolvedDecisionIDs.contains($0.id) }
    if snapshot.pendingDecisions.isEmpty, snapshot.session.status == .needsResponse,
      previousStatus != .needsResponse
    {
      snapshot.session.status = previousStatus
    }
    let committedIDs = Set(snapshot.messages.map(\.id))
    var insertedIDs: Set<String> = []
    for preview in previews {
      guard let oldPosition = previousMessages.firstIndex(where: { $0.id == preview.id }) else {
        continue
      }
      let nextAnchor = previousMessages.dropFirst(oldPosition + 1).compactMap { row in
        replacementAnchors[row.id] ?? (committedIDs.contains(row.id) ? row.id : nil)
      }.first
      if let nextAnchor, let index = snapshot.messages.firstIndex(where: { $0.id == nextAnchor }) {
        snapshot.messages.insert(preview, at: index)
      } else {
        let previousAnchor = previousMessages.prefix(oldPosition).reversed().compactMap { row in
          replacementAnchors[row.id]
            ?? (committedIDs.contains(row.id) || insertedIDs.contains(row.id) ? row.id : nil)
        }.first
        let position = previousAnchor.flatMap { anchor in
          snapshot.messages.firstIndex { $0.id == anchor }
        }
        snapshot.messages.insert(preview, at: position.map { $0 + 1 } ?? snapshot.messages.count)
      }
      insertedIDs.insert(preview.id)
    }
    if previews.contains(where: \.isStreaming) && snapshot.pendingDecisions.isEmpty {
      snapshot.session.status = .running
    }
  }

  mutating func apply(_ incoming: [String: JSONValue]) throws -> LiveEventEffects {
    var effects = LiveEventEffects()
    guard let rawType = incoming["type"]?.string else {
      throw LocalServerClientError.malformedResponse
    }
    let type =
      rawType.contains(".TaskStatus.")
      ? "response.\(rawType.split(separator: ".").last!.lowercased())" : rawType
    var event = incoming
    event["type"] = .string(type)
    if let id = event["conversation_id"]?.string ?? event["session_id"]?.string, id != snapshot.id {
      return effects
    }
    let startsResponse = [
      "response.created", "response.in_progress", "response.queued", "response.started",
    ].contains(type)
    let nativeDelta = type == "response.output_text.delta" && event["message_id"]?.string != nil
    if type.hasPrefix("response."), !startsResponse, !nativeDelta,
      type != "response.output_item.done",
      let id = eventResponseID(event), let responseID, id != responseID
    {
      return effects
    }
    if let supplemental = try applyPresentationEvent(event, type: type) {
      if supplemental.changed { snapshot.session.updatedAt = Date() }
      return supplemental
    }
    switch type {
    case "session.model", "session.reasoning_effort":
      if let id = event["conversation_id"]?.string, id != snapshot.id { return effects }
      let key = type == "session.model" ? "model" : "reasoning_effort"
      guard let value = event[key], value == .null || value.string != nil else { return effects }
      if var configuration = snapshot.session.configuration {
        if type == "session.model" {
          configuration.modelOverride = value.string
          configuration.modelReported = true
        } else {
          configuration.effort = value.string
          configuration.effortReported = true
        }
        snapshot.session.configuration = configuration
        effects.changed = true
      }
      effects.reconcile = true
    case "session.model_options", "session.agent_changed":
      if let id = event["conversation_id"]?.string, id != snapshot.id { return effects }
      effects.reconcile = true
    case "response.created", "response.in_progress", "response.queued", "response.started":
      let response = event["response"]?.object ?? event
      if let id = response["id"]?.string ?? event["response_id"]?.string {
        if endedResponseIDs.contains(id) { return effects }
        if type == "response.queued", responseID != nil, id != responseID,
          snapshot.session.status == .running
        {
          return effects
        }
        if id != responseID {
          if let previous = responseID {
            sealLiveContent(status: "stopped", preservingNativeText: true)
            endedResponseIDs.insert(previous)
          } else {
            for index in snapshot.messages.indices
            where snapshot.messages[index].id.hasPrefix("live:response:")
              && snapshot.messages[index].isStreaming
              && snapshot.messages[index].responseID == nil
            { snapshot.messages[index].responseID = id }
          }
          activeReasoningID = nil
          activitySequence = 0
          segment = 0
        }
        responseID = id
        if let previous = response["previous_response_id"]?.string, previous != id {
          endedResponseIDs.insert(previous)
        }
      }
      acceptsResponseDeltas = true
      acceptsNativeDeltas = true
      snapshot.session.failureMessage = nil
      observeLifecycle(event, type: type)
      snapshot.session.status = snapshot.pendingDecisions.isEmpty ? .running : .needsResponse
      effects.changed = true
    case "response.output_text.delta":
      guard let text = event["delta"]?.string else {
        throw LocalServerClientError.malformedResponse
      }
      let id: String
      if let messageID = event["message_id"]?.string {
        // Native message streams outlive the wrapper response that enqueues the turn.
        guard acceptsNativeDeltas else { return effects }
        if let response = eventResponseID(event), endedResponseIDs.contains(response) {
          return effects
        }
        if retiredNativeMessages.contains(messageID) { return effects }
        if let value = event["index"] {
          guard let index = value.validChunkIndex else { return effects }
          if let previous = nativeIndices[messageID], index <= previous { return effects }
          nativeIndices[messageID] = index
        }
        id = "live:\(messageID)"
      } else {
        guard acceptsResponseDeltas else { return effects }
        id = "live:response:\(responseID ?? "unidentified"):\(segment)"
        guard acceptsChunk(event, key: id) else { return effects }
      }
      closeReasoningSection()
      if let position = snapshot.messages.firstIndex(where: { $0.id == id }) {
        snapshot.messages[position].text += text
        snapshot.messages[position].isStreaming = true
      } else if !text.isEmpty {
        snapshot.messages.append(
          ConversationMessage(
            id: id, role: .assistant, text: text, isStreaming: true,
            responseID: nativeDelta ? eventResponseID(event) : responseID))
      }
      if event["final"]?.bool == true {
        if let position = snapshot.messages.firstIndex(where: { $0.id == id }) {
          snapshot.messages[position].isStreaming = false
        }
        if let messageID = event["message_id"]?.string {
          retiredNativeMessages.insert(messageID)
        } else {
          segment += 1
        }
      }
      snapshot.session.status = snapshot.pendingDecisions.isEmpty ? .running : .needsResponse
      effects.changed = true
    case "response.output_item.done":
      guard var item = event["item"]?.object else { throw LocalServerClientError.malformedResponse }
      if let nested = item["data"]?.object { item.merge(nested) { _, new in new } }
      if item["type"]?.string == "message", item["role"] == nil {
        item["role"] = .string("assistant")
      }
      if item["response_id"] == nil, let id = event["response_id"]?.string ?? responseID {
        item["response_id"] = .string(id)
      }
      let wire = try JSONDecoder().decode(
        ItemWire.self, from: JSONEncoder().encode(JSONValue.object(item)))
      if let message = try wire.message() {
        commit(message)
        effects.changed = true
      }
    case "session.input.consumed":
      guard let payload = event["data"]?.object, let id = payload["item_id"]?.string,
        let itemType = payload["type"]?.string, var item = payload["data"]?.object
      else {
        throw LocalServerClientError.malformedResponse
      }
      item["id"] = .string(id)
      item["type"] = .string(itemType)
      let wire = try JSONDecoder().decode(
        ItemWire.self, from: JSONEncoder().encode(JSONValue.object(item)))
      if let message = try wire.message() {
        commit(message)
        effects.changed = true
      }
      effects.consumedItemID = id
      effects.consumedPendingID = payload["cleared_pending_id"]?.string
    case "response.elicitation_request":
      let decision = try ElicitationWire(value: .object(event), sessionID: snapshot.id).decision
      if resolvedDecisionIDs.contains(decision.id)
        || snapshot.decisions.contains(where: { $0.id == decision.id && $0.response != nil })
      {
        return effects
      }
      snapshot.decisions.removeAll { $0.id == decision.id }
      snapshot.decisions.append(decision)
      snapshot.session.status = .needsResponse
      effects.changed = true
    case "response.elicitation_resolved":
      guard let id = event["elicitation_id"]?.string else {
        throw LocalServerClientError.malformedResponse
      }
      resolvedDecisionIDs.insert(id)
      guard snapshot.decisions.contains(where: { $0.id == id }) else { return effects }
      snapshot.decisions.removeAll { $0.id == id }
      if snapshot.pendingDecisions.isEmpty {
        snapshot.session.status = acceptsResponseDeltas && responseID != nil ? .running : .idle
      }
      effects.changed = true
      effects.reconcile = true
    case "session.status":
      if let id = event["conversation_id"]?.string, id != snapshot.id { return effects }
      guard let status = event["status"]?.string else {
        throw LocalServerClientError.malformedResponse
      }
      let reportedResponse = event["response_id"]?.string
      if ["idle", "failed"].contains(status), let reportedResponse, let responseID,
        reportedResponse != responseID
      {
        return effects
      }
      switch status {
      case "running", "waiting", "launching":
        if let reportedResponse, endedResponseIDs.contains(reportedResponse) { return effects }
        if let reportedResponse, reportedResponse != responseID {
          sealLiveContent(status: "stopped", preservingNativeText: true)
          if let responseID { endedResponseIDs.insert(responseID) }
          responseID = reportedResponse
          segment = 0
          activitySequence = 0
        }
        if !acceptsResponseDeltas, reportedResponse == nil {
          responseID = nil
          segment += 1
        }
        acceptsResponseDeltas = true
        acceptsNativeDeltas = true
        snapshot.session.status = .running
      case "idle", "failed":
        snapshot.session.status = .idle
        sealLiveContent(status: status == "failed" ? "failed" : "completed")
        acceptsResponseDeltas = false
        if let id = reportedResponse ?? responseID { endedResponseIDs.insert(id) }
        effects.reconcile = true
      default: return effects
      }
      observeLifecycle(event, type: type)
      if !snapshot.pendingDecisions.isEmpty { snapshot.session.status = .needsResponse }
      effects.error = event["error"]?.object?["message"]?.string
      if effects.error != nil, let error = event["error"] {
        presentError(error, source: "execution")
      }
      effects.changed = true
    case "response.completed", "response.failed", "response.incomplete", "response.cancelled",
      "session.interrupted":
      let response = event["response"]?.object ?? event["data"]?.object ?? event
      let endedID = response["id"]?.string ?? response["response_id"]?.string
      if let endedID, let responseID, endedID != responseID { return effects }
      observeLifecycle(event, type: type)
      acceptsResponseDeltas = false
      if type != "response.completed" {
        acceptsNativeDeltas = false
        for message in snapshot.messages where isNativePreview(message) {
          retiredNativeMessages.insert(String(message.id.dropFirst("live:".count)))
        }
      }
      if let endedID = endedID ?? responseID { endedResponseIDs.insert(endedID) }
      snapshot.session.status = snapshot.pendingDecisions.isEmpty ? .idle : .needsResponse
      if ["response.cancelled", "session.interrupted"].contains(type),
        let index = snapshot.messages.lastIndex(where: {
          $0.role == .assistant
            && ($0.isStreaming || (responseID != nil && $0.responseID == responseID))
        })
      {
        snapshot.messages[index].interrupted = true
      }
      sealLiveContent(
        status: type.hasSuffix("completed") ? "completed" : "stopped",
        preservingNativeText: type == "response.completed")
      if snapshot.pendingDecisions.isEmpty, snapshot.messages.contains(where: \.isStreaming) {
        snapshot.session.status = .running
      }
      effects.error = response["error"]?.object?["message"]?.string
      if type == "response.incomplete", effects.error == nil {
        effects.error =
          response["incomplete_details"]?.object?["reason"]?.string
          ?? response["incompleteDetails"]?.object?["reason"]?.string ?? event["reason"]?.string
      }
      if let error = effects.error {
        presentError(
          response["error"] ?? .object(["message": .string(error)]), source: event["source"]?.string
        )
      }
      effects.changed = true
      effects.reconcile = true
    default:
      return presentUnknownEvent(event, type: type)
    }
    if effects.changed { snapshot.session.updatedAt = Date() }
    if let error = effects.error { snapshot.session.failureMessage = error }
    return effects
  }

  mutating func commit(_ message: ConversationMessage) {
    // Replayed old commits must not consume a newer preview with the same call or response.
    if let position = snapshot.messages.firstIndex(where: { $0.id == message.id }) {
      snapshot.messages[position] = message
      return
    }
    if let position = snapshot.messages.firstIndex(where: {
      matchesActivity($0, message) || matchesText($0, message)
    }) {
      retirePreview(snapshot.messages[position])
      snapshot.messages[position] = message
    } else {
      snapshot.messages.append(message)
    }
  }

  func matchesActivity(_ preview: ConversationMessage, _ committed: ConversationMessage) -> Bool {
    guard isEphemeral(preview),
      let first = preview.activity, let second = committed.activity, first.kind == second.kind
    else { return false }
    if let lhs = preview.responseID, let rhs = committed.responseID, lhs != rhs { return false }
    if let source = activityItemIDs[preview.id] { return source == committed.id }
    if let call = preview.callID { return call == committed.callID }
    switch first.kind {
    case .reasoning:
      let prefix = first.details.first(where: { $0.id == "summary" })?.text ?? ""
      let full = second.details.first(where: { $0.id == "summary" })?.text ?? ""
      return prefix.isEmpty || full.hasPrefix(prefix) || (!full.isEmpty && prefix.hasPrefix(full))
    case .compaction: return first.status != "failed"
    case .error:
      let firstCode = first.details.first(where: { $0.id == "code" })?.text
      let secondCode = second.details.first(where: { $0.id == "code" })?.text
      return first.summary == second.summary
        && (firstCode == nil || secondCode == nil || firstCode == secondCode)
    default: return false
    }
  }

  func matchesText(_ preview: ConversationMessage, _ committed: ConversationMessage) -> Bool {
    guard preview.id.hasPrefix("live:"), preview.role == .assistant, preview.activity == nil,
      committed.role == .assistant, committed.activity == nil
    else { return false }
    if let first = preview.responseID, let second = committed.responseID, first != second {
      return false
    }
    if preview.id == "live:\(committed.id)" { return true }
    guard !preview.text.isEmpty, !committed.text.isEmpty else { return false }
    return committed.text.hasPrefix(preview.text) || preview.text.hasPrefix(committed.text)
  }

  func isEphemeral(_ message: ConversationMessage) -> Bool {
    message.id.hasPrefix("live:") || message.id.hasPrefix("event:")
  }

  mutating func retirePreview(_ preview: ConversationMessage) {
    if preview.activity != nil {
      retiredActivityIDs.insert(preview.id)
      activityBuffers.removeValue(forKey: preview.id)
      if activeReasoningID == preview.id {
        activeReasoningID = nil
        activitySequence += 1
      }
    } else if !preview.id.hasPrefix("live:response:") {
      retiredNativeMessages.insert(String(preview.id.dropFirst("live:".count)))
    } else if preview.id == "live:response:\(responseID ?? "unidentified"):\(segment)" {
      segment += 1
    }
  }

  func eventResponseID(_ event: [String: JSONValue]) -> String? {
    event["response_id"]?.string ?? event["response"]?.object?["id"]?.string
      ?? event["data"]?.object?["response_id"]?.string
  }

  mutating func closeTextSection() {
    let id = "live:response:\(responseID ?? "unidentified"):\(segment)"
    if let index = snapshot.messages.firstIndex(where: { $0.id == id }) {
      snapshot.messages[index].isStreaming = false
      segment += 1
    }
  }

  mutating func closeReasoningSection() {
    guard let id = activeReasoningID else { return }
    if let index = snapshot.messages.firstIndex(where: { $0.id == id }) {
      snapshot.messages[index].isStreaming = false
      snapshot.messages[index].activity?.status = "completed"
    }
    activeReasoningID = nil
    activitySequence += 1
  }

  func isNativePreview(_ message: ConversationMessage) -> Bool {
    message.id.hasPrefix("live:") && !message.id.hasPrefix("live:response:")
      && message.activity == nil
  }

  mutating func sealLiveContent(status: String, preservingNativeText: Bool = false) {
    for index in snapshot.messages.indices where snapshot.messages[index].isStreaming {
      if preservingNativeText && isNativePreview(snapshot.messages[index]) { continue }
      snapshot.messages[index].isStreaming = false
      if snapshot.messages[index].activity != nil {
        snapshot.messages[index].activity?.status = status
      }
    }
    if activeReasoningID != nil {
      activeReasoningID = nil
      activitySequence += 1
    }
  }
}
