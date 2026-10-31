import Foundation

public struct ConversationActivity: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Equatable, Sendable {
    case toolCall, toolResult, nativeTool, reasoning, compaction, command, terminal, routing
    case resource, error, unknown, retry, file, policy, clientTask, browser
  }

  public var kind: Kind
  public var title: String
  public var summary: String
  public var status: String?
  public var details: [ConversationDetailSection]

  public var isFailure: Bool {
    kind == .error || ["failed", "error", "denied"].contains(status?.lowercased() ?? "")
  }

  public var isRoutineLifecycle: Bool {
    guard !isFailure else { return false }
    return kind == .resource
      || (kind == .clientTask
        && ["cancelled", "canceled", "completed"].contains(
          status?.lowercased() ?? ""))
  }

  public init(
    kind: Kind, title: String, summary: String, status: String? = nil,
    details: [ConversationDetailSection] = []
  ) {
    self.kind = kind
    self.title = title
    self.summary = summary
    self.status = status
    self.details = details
  }
}

extension ConversationMessage {
  public var isActivityOnly: Bool {
    role == .tool && activity?.isRoutineLifecycle == true && (attachments ?? []).isEmpty
  }
}

extension ConversationSnapshot {
  public var transcriptMessages: [ConversationMessage] {
    messages.filter { !$0.isActivityOnly }
  }

  public var lifecycleMessages: [ConversationMessage] {
    messages.filter(\.isActivityOnly)
  }
}

public struct ConversationDetailSection: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public var title: String
  public var text: String
  public var isCode: Bool

  public init(id: String, title: String, text: String, isCode: Bool = false) {
    self.id = id
    self.title = title
    self.text = text
    self.isCode = isCode
  }
}

public struct ConversationAttachment: Identifiable, Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Equatable, Sendable {
    case image, file, audio, video, unknown
  }

  public let id: String
  public var kind: Kind
  public var title: String
  /// A display-only file ID or reference. Views must not fetch arbitrary references automatically.
  public var reference: String?
  public var mimeType: String?
  public var isEmbedded: Bool

  public init(
    id: String, kind: Kind, title: String, reference: String? = nil,
    mimeType: String? = nil, isEmbedded: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.reference = reference
    self.mimeType = mimeType
    self.isEmbedded = isEmbedded
  }
}

extension JSONValue {
  /// Bounded, display-only inspection of provider data. Never expose hidden reasoning or credentials.
  var safeDisplayText: String {
    var remainingNodes = 200
    let cleaned = displayValue(depth: 0, remainingNodes: &remainingNodes)
    return (cleaned?.plainDisplayText ?? "").boundedDisplay(16_000)
  }

  private func displayValue(depth: Int, remainingNodes: inout Int) -> JSONValue? {
    guard remainingNodes > 0, depth < 7 else { return .string("[Additional details omitted]") }
    remainingNodes -= 1
    switch self {
    case .string(let value):
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
        guard value.utf8.count <= 262_144 else {
          return .string("[Large structured payload omitted]")
        }
        if let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(value.utf8)) {
          return decoded.displayValue(depth: depth + 1, remainingNodes: &remainingNodes)
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[\"") || trimmed.hasPrefix("[{") {
          return .string("[Structured payload is incomplete]")
        }
      }
      if trimmed.lowercased().hasPrefix("data:") || Self.looksLikeBinary(trimmed) {
        return .string("[Embedded data omitted]")
      }
      return .string(value.boundedDisplay(8_000))
    case .array(let values):
      var result: [JSONValue] = []
      for value in values.prefix(40) where remainingNodes > 0 {
        if let value = value.displayValue(depth: depth + 1, remainingNodes: &remainingNodes) {
          result.append(value)
        }
      }
      if values.count > result.count {
        result.append(.string("[Additional or private content omitted]"))
      }
      return .array(result)
    case .object(let fields):
      if fields["is_meta"]?.bool == true || fields["hidden"]?.bool == true
        || fields["is_hidden"]?.bool == true
      {
        return nil
      }
      let type = fields["type"]?.string?.lowercased() ?? ""
      if Self.privateContentTypes.contains(type) {
        guard let summary = fields["summary"] else { return nil }
        return summary.displayValue(depth: depth + 1, remainingNodes: &remainingNodes)
      }
      var result: [String: JSONValue] = [:]
      for key in fields.keys.sorted().prefix(40) where remainingNodes > 0 {
        guard !Self.isPrivateDisplayKey(key), let value = fields[key] else { continue }
        if let cleaned = value.displayValue(depth: depth + 1, remainingNodes: &remainingNodes) {
          result[key.boundedDisplay(100)] = cleaned
        }
      }
      if fields.count > 40 { result["…"] = .string("Additional fields omitted") }
      return .object(result)
    default: return self
    }
  }

  static let privateContentTypes: Set<String> = [
    "reasoning", "reasoning_text", "thinking", "redacted_thinking", "encrypted_reasoning",
    "hidden_reasoning", "chain_of_thought", "analysis", "analysis_text", "redacted_reasoning",
  ]

  private static func isPrivateDisplayKey(_ key: String) -> Bool {
    let key = key.lowercased().filter { $0.isLetter || $0.isNumber }
    return [
      "authorization", "proxyauthorization", "cookie", "setcookie", "credentials", "credential",
      "apikey", "xapikey", "accesskey", "privatekey", "token", "accesstoken", "refreshtoken",
      "idtoken", "sessiontoken", "authtoken", "bearer", "accesskeyid", "reasoning", "thinking",
      "reasoningcontent", "reasoningtext", "rawreasoning", "hiddenreasoning", "thinkingtext",
      "thinkingcontent", "hiddenthoughts", "analysis", "chainofthought",
      "hiddencontent", "filedata", "imagedata", "audiodata", "b64json", "signature",
      "compactedmessages",
    ].contains(key) || key.contains("password") || key.contains("secret")
      || key.contains("encrypted") || key.contains("base64")
  }

  private static func looksLikeBinary(_ value: String) -> Bool {
    guard value.utf8.count > 256 else { return false }
    return value.utf8.allSatisfy {
      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
        || $0 == 43 || $0 == 47 || $0 == 61 || $0 == 10 || $0 == 13
    }
  }

  private var plainDisplayText: String {
    switch self {
    case .string(let value): return value
    case .array(let values): return values.map(\.plainDisplayText).joined(separator: "\n")
    case .object(let fields):
      if let text = fields["text"]?.string,
        fields.count == 1
          || ["text", "input_text", "output_text", "summary_text"].contains(
            fields["type"]?.string ?? "")
      {
        return text
      }
      return fields.keys.sorted().map { "\($0): \(fields[$0]?.plainDisplayText ?? "")" }.joined(
        separator: "\n")
    case .number(let value):
      return value == value.rounded() ? String(format: "%.0f", value) : String(value)
    case .bool(let value): return value ? "true" : "false"
    case .null: return ""
    }
  }
}

extension String {
  func boundedDisplay(_ limit: Int = 320) -> String {
    guard let end = index(startIndex, offsetBy: limit, limitedBy: endIndex), end != endIndex else {
      return self
    }
    return String(self[..<end]) + "\n[Truncated]"
  }
}

struct ConversationContentPresentation {
  var text = ""
  var attachments: [ConversationAttachment] = []
  var details: [ConversationDetailSection] = []

  init(value: JSONValue, itemID: String) throws {
    if let value = value.string {
      text = value
      return
    }
    guard let parts = value.array else { throw LocalServerClientError.malformedResponse }
    var texts: [String] = []
    for (index, part) in parts.enumerated() {
      guard let fields = part.object, let type = fields["type"]?.string else {
        throw LocalServerClientError.malformedResponse
      }
      if fields["is_meta"]?.bool == true || fields["hidden"]?.bool == true
        || fields["is_hidden"]?.bool == true
      {
        continue
      }
      if JSONValue.privateContentTypes.contains(type) { continue }
      switch type {
      case "input_text", "output_text", "text", "refusal":
        guard let text = fields[type == "refusal" ? "refusal" : "text"]?.string else {
          throw LocalServerClientError.malformedResponse
        }
        texts.append(text)
      case "input_image", "output_image", "image", "image_url", "input_file", "output_file", "file",
        "input_audio", "output_audio", "audio", "input_video", "output_video", "video":
        let kind: ConversationAttachment.Kind =
          type.contains("image")
          ? .image
          : type.contains("audio")
            ? .audio
            : type.contains("video") ? .video : .file
        let rawReference =
          fields["file_id"]?.string ?? fields["file_url"]?.string
          ?? fields["image_url"]?.string ?? fields["image_url"]?.object?["url"]?.string
          ?? fields["url"]?.string ?? fields["source"]?.object?["url"]?.string
        let embedded =
          rawReference?.lowercased().hasPrefix("data:") == true
          || [fields["file_data"], fields["data"], fields["source"]?.object?["data"]]
            .contains { $0 != nil && $0 != .null }
        let title =
          fields["filename"]?.string ?? fields["name"]?.string
          ?? "\(kind.rawValue.capitalized) attachment"
        attachments.append(
          ConversationAttachment(
            id: "\(itemID)-attachment-\(index)", kind: kind, title: title.boundedDisplay(200),
            reference: fields["file_id"]?.string?.boundedDisplay(2_000)
              ?? (embedded ? nil : rawReference?.boundedDisplay(2_000)),
            mimeType: (fields["mime_type"]?.string ?? fields["media_type"]?.string
              ?? fields["source"]?.object?["media_type"]?.string)?.boundedDisplay(200),
            isEmbedded: embedded))
      default:
        let detail = part.safeDisplayText
        if !detail.isEmpty {
          details.append(
            ConversationDetailSection(
              id: "content-\(index)", title: type.replacingOccurrences(of: "_", with: " "),
              text: detail, isCode: true))
        }
      }
    }
    text = texts.joined(separator: "\n")
  }
}

struct ConversationItemPresentation {
  let item: ItemWire

  func message() throws -> ConversationMessage? {
    let data = item.payload
    if item.isMeta == true { return nil }
    switch item.type {
    case "message":
      guard let role = item.role, let role = MessageRole(rawValue: role), let content = item.content
      else {
        throw LocalServerClientError.malformedResponse
      }
      let presentation = try ConversationContentPresentation(value: content, itemID: item.id)
      if role == .user {
        let texts = content.array?.compactMap { $0.object?["text"]?.string } ?? [presentation.text]
        if texts.contains(where: isHiddenContext) { return nil }
      }
      let activity: ConversationActivity? =
        presentation.details.isEmpty
        ? nil
        : ConversationActivity(
          kind: .unknown, title: "Message content", summary: presentation.text.boundedDisplay(),
          status: item.status, details: presentation.details)
      return ConversationMessage(
        id: item.id, role: role, text: presentation.text, activity: activity,
        attachments: presentation.attachments.isEmpty ? nil : presentation.attachments,
        responseID: item.responseID, interrupted: data["interrupted"]?.bool,
        author: data["created_by"]?.string, agent: data["model"]?.string ?? data["agent"]?.string)
    case "function_call":
      let arguments = item.arguments?.safeDisplayText ?? ""
      let name = (item.name ?? "Tool").boundedDisplay(160)
      return activity(
        .toolCall, title: name, summary: arguments,
        details: sections(("arguments", "Arguments", arguments, true)),
        text: "Tool call: \(item.name ?? "unknown")\(arguments.isEmpty ? "" : "\n\(arguments)")")
    case "function_call_output":
      let output = item.output?.safeDisplayText ?? "[Tool output unavailable]"
      return activity(
        .toolResult, title: item.name ?? "Tool result", summary: output,
        details: sections(("output", "Output", output, true)), text: output)
    case "error":
      guard let code = item.code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let message = item.errorMessage,
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw LocalServerClientError.malformedResponse }
      return activity(
        .error, title: "Response error", summary: message, status: "failed",
        details: sections(
          ("message", "Error", message.boundedDisplay(16_000), false),
          ("code", "Code", code, true), ("source", "Source", data["source"]?.string ?? "", false)),
        text: "Error (\(code)): \(message)")
    case "reasoning":
      let summary = reasoningSummary(data["summary"])
      return activity(
        .reasoning, title: "Reasoning summary",
        summary: summary.isEmpty ? "No public reasoning summary was provided." : summary,
        details: sections(("summary", "Summary", summary, false)))
    case "compaction":
      let summary = data["summary"]?.safeDisplayText ?? ""
      return activity(
        .compaction, title: "Context compacted",
        summary: summary.isEmpty ? "Earlier context was summarized for this session." : summary,
        details: sections(
          ("summary", "Summary", summary, false),
          ("model", "Model", data["model"]?.string ?? "", false),
          ("tokens", "Summary tokens", data["token_count"]?.safeDisplayText ?? "", false),
          ("through", "Through item", data["last_item_id"]?.string ?? "", true)))
    case "slash_command":
      let name = (item.name ?? "command").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      let arguments = item.arguments?.safeDisplayText ?? ""
      let command = "/\(name)\(arguments.isEmpty ? "" : " \(arguments)")"
      let output = item.output?.safeDisplayText ?? ""
      return activity(
        .command, title: data["kind"]?.string == "command" ? "Command /\(name)" : "Skill /\(name)",
        summary: command,
        details: sections(
          ("invocation", "Invocation", command, true), ("output", "Output", output, true)))
    case "terminal_command":
      let isInput = data["kind"]?.string == "input"
      let input = data["input"]?.safeDisplayText ?? ""
      let stdout = data["stdout"]?.safeDisplayText ?? ""
      let stderr = data["stderr"]?.safeDisplayText ?? ""
      return activity(
        .terminal, title: isInput ? "Terminal command" : "Terminal output",
        summary: isInput ? input : [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n"),
        details: sections(
          ("input", "Command", input, true), ("stdout", "Standard output", stdout, true),
          ("stderr", "Standard error", stderr, true)))
    case "routing_decision":
      let model = data["model"]?.string ?? "Unreported model"
      let title = data["applied"]?.bool == true ? "Using \(model)" : "Would have picked \(model)"
      return activity(
        .routing, title: title, summary: data["rationale"]?.safeDisplayText ?? "",
        details: sections(
          ("rationale", "Rationale", data["rationale"]?.safeDisplayText ?? "", false),
          ("agent", "Agent", data["agent"]?.string ?? "", false)))
    case "resource_event":
      let event = data["event_type"]?.string ?? ""
      let verb =
        event.hasSuffix(".deleted")
        ? "deleted" : event.hasSuffix(".created") ? "created" : "updated"
      let resourceType = data["resource_type"]?.string ?? "resource"
      let resource = data["resource"]?.object
      let name =
        resource?["name"]?.string ?? resource?["path"]?.string
        ?? resource?["title"]?.string ?? data["resource_id"]?.string ?? ""
      return activity(
        .resource, title: "\(resourceType.capitalized) \(verb)", summary: name,
        details: sections(
          ("event", "Event", event, true),
          ("id", "Resource ID", data["resource_id"]?.string ?? "", true),
          ("resource", "Resource", data["resource"]?.safeDisplayText ?? "", true)))
    case "native_tool":
      let native = data["item"]?.object ?? data["data"]?.object?["item"]?.object ?? data
      return nativeTool(native, type: native["type"]?.string ?? "native_tool")
    case "web_search_call", "file_search_call", "code_interpreter_call", "computer_call",
      "image_generation_call", "mcp_call", "mcp_list_tools":
      return nativeTool(data, type: item.type)
    default:
      let details = JSONValue.object(data).safeDisplayText
      return activity(
        .unknown, title: item.type.replacingOccurrences(of: "_", with: " ").capitalized,
        summary: data["message"]?.safeDisplayText ?? data["summary"]?.safeDisplayText
          ?? "Additional session activity",
        details: sections(("payload", "Event details", details, true)))
    }
  }

  private func nativeTool(_ data: [String: JSONValue], type: String) -> ConversationMessage {
    let action = data["action"]?.object ?? [:]
    let title: String
    let summary: String
    switch type {
    case "web_search_call":
      title = action["type"]?.string == "open_page" ? "Open web page" : "Web search"
      summary =
        action["query"]?.safeDisplayText ?? action["url"]?.safeDisplayText
        ?? action["pattern"]?.safeDisplayText ?? "Provider web activity"
    case "file_search_call":
      title = "File search"
      summary = data["queries"]?.safeDisplayText ?? "Search session files"
    case "code_interpreter_call":
      title = "Code interpreter"
      summary = data["code"]?.safeDisplayText ?? "Provider code execution"
    case "computer_call":
      title = "Computer action"
      summary = data["action"]?.safeDisplayText ?? "Provider computer activity"
    case "image_generation_call":
      title = "Image generation"
      summary =
        data["revised_prompt"]?.safeDisplayText ?? data["prompt"]?.safeDisplayText
        ?? "Generated image output"
    case "mcp_call":
      title = "MCP: \(data["name"]?.string ?? "tool")"
      summary =
        data["arguments"]?.safeDisplayText ?? data["server_label"]?.safeDisplayText
        ?? "Provider tool call"
    case "mcp_list_tools":
      title = "Available MCP tools"
      summary = data["server_label"]?.safeDisplayText ?? "Provider tool discovery"
    default:
      title = type.replacingOccurrences(of: "_", with: " ").capitalized
      summary = "Provider tool activity"
    }
    var details = data
    if type == "image_generation_call" { details.removeValue(forKey: "result") }
    var result = activity(
      .nativeTool, title: title, summary: summary, status: data["status"]?.string,
      details: sections(
        ("provider", "Provider details", JSONValue.object(details).safeDisplayText, true)))
    result.callID = item.callID ?? data["call_id"]?.string
    if type == "image_generation_call", let output = data["result"], output != .null,
      output.string?.isEmpty != true
    {
      result.attachments = [
        ConversationAttachment(
          id: "\(item.id)-image", kind: .image, title: "Generated image", isEmbedded: true)
      ]
    }
    return result
  }

  private func activity(
    _ kind: ConversationActivity.Kind, title: String, summary: String, status: String? = nil,
    details: [ConversationDetailSection] = [], text: String? = nil
  ) -> ConversationMessage {
    let title = title.boundedDisplay(200)
    let summary = summary.boundedDisplay()
    return ConversationMessage(
      id: item.id, role: .tool,
      text: text ?? [title, summary].filter { !$0.isEmpty }.joined(separator: "\n"),
      activity: ConversationActivity(
        kind: kind, title: title, summary: summary, status: status ?? item.status, details: details),
      callID: item.callID, responseID: item.responseID,
      author: item.payload["created_by"]?.string,
      agent: item.payload["model"]?.string ?? item.payload["agent"]?.string)
  }

  private func sections(_ values: (String, String, String, Bool)...) -> [ConversationDetailSection]
  {
    values.filter { !$0.2.isEmpty }.map {
      ConversationDetailSection(
        id: $0.0, title: $0.1, text: $0.2.boundedDisplay(16_000), isCode: $0.3)
    }
  }

  private func reasoningSummary(_ value: JSONValue?) -> String {
    guard let parts = value?.array else { return "" }
    return parts.prefix(40).compactMap { part -> String? in
      guard let block = part.object, block["type"]?.string == "summary_text" else { return nil }
      return block["text"]?.string?.boundedDisplay(8_000)
    }.joined(separator: "\n\n").boundedDisplay(16_000)
  }

  private func isHiddenContext(_ text: String) -> Bool {
    if text.hasPrefix("This session is being continued from a previous conversation") {
      return true
    }
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.hasPrefix("<task-notification>") && text.contains("<task-id>")
      && text.contains("</task-notification>")
  }
}
