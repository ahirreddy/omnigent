import Foundation

public struct MessageSubmission: Equatable, Sendable, Decodable {
  public let queued: Bool
  public let itemID: String?
  public let pendingID: String?
  public let denied: Bool

  enum CodingKeys: String, CodingKey {
    case queued, denied
    case itemID = "item_id"
    case pendingID = "pending_id"
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    queued = try values.decode(Bool.self, forKey: .queued)
    itemID = try values.decodeIfPresent(String.self, forKey: .itemID)
    pendingID = try values.decodeIfPresent(String.self, forKey: .pendingID)
    denied = try values.decodeIfPresent(Bool.self, forKey: .denied) ?? false
  }
}

public enum LiveConnectionState: Equatable, Sendable {
  case connecting
  case live
  case reconnecting
  case stopped
  case failed(String)
}

public enum LocalServerActivity: Equatable, Sendable {
  case streamState(sessionID: String, state: LiveConnectionState)
  case listState(LiveConnectionState)
  case sessionsChanged([SessionSummary])
  case sessionsRemoved([String])
  case inventoryInvalidated
  case historyCursor(sessionID: String, nextCursor: String?, firstMessageID: String?)
  case inputConsumed(sessionID: String, itemID: String, pendingID: String?)
  case error(String)
  case conversationError(sessionID: String, message: String)
}

/// An SSE frame is complete only at a blank line; comment heartbeats are ignored.
struct ServerSentEvent: Equatable, Sendable {
  let event: String?
  let data: String
}

struct ServerSentEventParser {
  private var event: String?
  private var data: [String] = []
  private var size = 0

  mutating func consume(_ line: String) throws -> ServerSentEvent? {
    if line.isEmpty {
      defer {
        event = nil
        data = []
        size = 0
      }
      return data.isEmpty ? nil : ServerSentEvent(event: event, data: data.joined(separator: "\n"))
    }
    if line.hasPrefix(":") { return nil }
    size += line.utf8.count
    guard size <= 4 * 1_024 * 1_024 else { throw LocalServerClientError.malformedResponse }
    let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    var value = fields.count == 2 ? String(fields[1]) : ""
    if value.hasPrefix(" ") { value.removeFirst() }
    switch fields[0] {
    case "event": event = value
    case "data": data.append(value)
    default: break
    }
    return nil
  }
}

/// AsyncBytes.lines omits empty lines on this runtime; SSE requires those delimiters.
struct ServerSentEventByteParser {
  private var parser = ServerSentEventParser()
  private var line: [UInt8] = []
  private var previousWasCR = false
  private var firstLine = true

  mutating func consume(_ byte: UInt8) throws -> ServerSentEvent? {
    if byte == 10 && previousWasCR {
      previousWasCR = false
      return nil
    }
    previousWasCR = byte == 13
    guard byte == 10 || byte == 13 else {
      guard line.count < 4 * 1_024 * 1_024 else { throw LocalServerClientError.malformedResponse }
      line.append(byte)
      return nil
    }
    guard var text = String(bytes: line, encoding: .utf8) else {
      throw LocalServerClientError.malformedResponse
    }
    line.removeAll(keepingCapacity: true)
    if firstLine && text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    firstLine = false
    return try parser.consume(text)
  }
}

struct ElicitationWire {
  let decision: DecisionRequest

  init(value: JSONValue, sessionID: String) throws {
    guard let root = value.object, let id = root["elicitation_id"]?.string, !id.isEmpty,
      let params = root["params"]?.object
    else { throw LocalServerClientError.malformedResponse }
    let schema = params["requestedSchema"]?.object ?? [:]
    let properties = schema["properties"]?.object ?? [:]
    let target = params["target_session_id"]?.string ?? sessionID
    var key: String?
    var options: [String] = []
    var unsupported: String?
    var form: DecisionForm?
    var externalURL: String?
    if let requestedSchema = params["requestedSchema"], requestedSchema != .null,
      requestedSchema.object == nil
    {
      unsupported = "This form uses a schema that needs the web app."
    }
    if properties.count == 1, let field = properties.keys.first,
      let property = properties[field]?.object,
      Set(property.keys).isSubset(of: ["type", "enum"]),
      let values = properties[field]?.object?["enum"]?.array,
      !values.isEmpty, values.allSatisfy({ $0.string != nil }),
      DecisionForm.parseSchema(schema) != nil
    {
      key = field
      options = values.compactMap(\.string)
    } else if !properties.isEmpty {
      form = DecisionForm.parseSchema(schema)
      if form == nil { unsupported = "This form uses a schema that needs the web app." }
    } else if !schema.isEmpty
      && (schema["type"] != nil && schema["type"] != .string("object")
        || schema["properties"] != nil && schema["properties"]?.object == nil
        || !Set(schema.keys).isSubset(of: [
          "type", "properties", "title", "description", "$schema", "additionalProperties",
        ]))
    {
      unsupported = "This form uses a schema that needs the web app."
    }
    let preview = params["content_preview"]?.string ?? ""
    var question = params["ask_user_question"]
    if question == nil, preview.hasPrefix("AskUserQuestion("), preview.hasSuffix(")"),
      let data = String(preview.dropFirst("AskUserQuestion(".count).dropLast()).data(using: .utf8)
    {
      question = try? JSONDecoder().decode(JSONValue.self, from: data)
    }
    if let question, question != .null {
      form = DecisionForm.parseQuestions(question)
      options = []
      key = nil
      unsupported =
        form == nil ? "This structured question needs the web app's question form." : nil
    }
    if let url = params["url"]?.string, !url.isEmpty, !url.hasPrefix("/approve/") {
      if let parsed = URL(string: url),
        ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""),
        parsed.host != nil, parsed.user == nil, parsed.password == nil
      {
        externalURL = url
        unsupported =
          "Complete this request on its confirmation page. The session will update when the server receives your response."
      } else {
        unsupported =
          "This request uses a confirmation address that cannot be opened safely here. Continue in the web app."
      }
    }
    if let mode = params["mode"]?.string, !["form", "url"].contains(mode) {
      unsupported = "This request type is not supported in the native app yet."
    }
    if params["mode"] == .string("url"), params["url"]?.string?.isEmpty != false {
      unsupported =
        "The server did not provide a confirmation address. Continue this request in the web app."
    }
    let command = params["command"]?.string ?? ""
    let plan = params["exit_plan_mode"]?.object?["plan"]?.string ?? ""
    let amendment = params["execpolicy_amendment"]?.array
    let validAmendment =
      amendment?.isEmpty == false && amendment?.allSatisfy({ $0.string?.isEmpty == false }) == true
    let execPolicyAmendment = validAmendment ? amendment?.compactMap(\.string) : nil
    let commandDetails = ["cwd", "reason"].compactMap { key -> String? in
      guard let value = params[key]?.string, !value.isEmpty else { return nil }
      return "\(key == "cwd" ? "Working directory" : "Reason"): \(value)"
    }
    let policyDescription =
      execPolicyAmendment.map { "Suggested command policy: " + $0.joined(separator: " ") } ?? ""
    let detail =
      ([
        params["message"]?.string ?? "", command, form == nil ? preview : "", plan,
        policyDescription,
      ] + commandDetails)
      .filter { !$0.isEmpty }.joined(separator: "\n\n")
    let remember = params["remember_scope"]?.object
    let rememberLabel = remember?["host"]?.string ?? remember?["tool"]?.string
    decision = DecisionRequest(
      id: id, targetSessionID: target,
      title: !plan.isEmpty
        ? "Review the plan"
        : (options.isEmpty && form == nil ? "Approval requested" : "Response requested"),
      detail: detail.isEmpty ? "The server is waiting for your response." : detail,
      options: options, answerKey: key, unsupportedReason: unsupported,
      form: form, externalURL: externalURL,
      allowAllEdits: params["allow_all_edits"] == .bool(true) || !plan.isEmpty,
      rememberLabel: rememberLabel, isPlanReview: !plan.isEmpty,
      execPolicyAmendment: execPolicyAmendment)
  }
}
