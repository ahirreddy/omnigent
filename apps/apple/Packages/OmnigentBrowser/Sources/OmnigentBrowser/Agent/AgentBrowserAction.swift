public import Foundation

/// A JSON value: action arguments as the server sent them, and result data as it expects them.
nonisolated public enum AgentJSONValue: Sendable, Hashable, Codable {
  /// `null`.
  case null
  /// A boolean.
  case bool(Bool)
  /// A number.
  case number(Double)
  /// A string.
  case string(String)
  /// An array.
  case array([Self])
  /// An object.
  case object([String: Self])

  /// Decodes any JSON value.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let bool = try? container.decode(Bool.self) {
      // `try?` probes the JSON type; a mismatch is not an error, the next type is tried.
      self = .bool(bool)
    } else if let number = try? container.decode(Double.self) {
      self = .number(number)
    } else if let string = try? container.decode(String.self) {
      self = .string(string)
    } else if let array = try? container.decode([Self].self) {
      self = .array(array)
    } else {
      self = .object(try container.decode([String: Self].self))
    }
  }

  /// Encodes the value.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  /// The string, if this is one.
  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  /// The number, if this is one.
  public var numberValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  /// A script result as JSON. `undefined`, `NaN` and infinities become `null`.
  public init(_ value: BrowserScriptValue) {
    switch value {
    case .undefined, .null: self = .null
    case .bool(let bool): self = .bool(bool)
    case .number(let number): self = number.isFinite ? .number(number) : .null
    case .string(let string): self = .string(string)
    case .array(let array): self = .array(array.map(Self.init))
    case .object(let object): self = .object(object.mapValues(Self.init))
    }
  }
}

extension AgentJSONValue: ExpressibleByStringLiteral {
  /// A string value.
  public init(stringLiteral value: String) {
    self = .string(value)
  }
}

/// One `browser.action_request` from the server: run `action` with `args` in the agent browser
/// of `conversationID`. See OmnigentWebLayer/DESIGN.md, "Agent browser actions".
nonisolated public struct AgentBrowserActionRequest: Sendable, Hashable {
  /// The server's correlation ID, for example "baction_abc123". Echoed on claim and result.
  public let actionID: String
  /// The `browser_` tool name without the prefix: navigate, snapshot, click, type, screenshot,
  /// and the client extensions press, scroll, evaluate, wait_for_load.
  public let action: String
  /// The tool arguments.
  public let args: [String: AgentJSONValue]
  /// The session whose stream delivered the event; it owns the action.
  public let conversationID: String

  /// Creates a request.
  public init(
    actionID: String, action: String, args: [String: AgentJSONValue], conversationID: String
  ) {
    self.actionID = actionID
    self.action = action
    self.args = args
    self.conversationID = conversationID
  }

  /// Decodes the raw event object `{"type": "browser.action_request", "action_id", "action",
  /// "args"}`. A missing or null `args` is an empty object, as on the server.
  public init(eventJSON: Data, conversationID: String) throws(BrowserError) {
    let event: ActionRequestEvent
    do {
      event = try JSONDecoder().decode(ActionRequestEvent.self, from: eventJSON)
    } catch {
      throw .agentActionFailed("Malformed browser.action_request event: \(error)")
    }
    if let type = event.type, type != "browser.action_request" {
      throw .agentActionFailed("Expected a browser.action_request event, got \(type).")
    }
    guard !event.action.isEmpty, !event.actionID.isEmpty else {
      throw .agentActionFailed("browser.action_request needs a non-empty action and action_id.")
    }
    self.init(
      actionID: event.actionID, action: event.action, args: event.args,
      conversationID: conversationID)
  }
}

/// The wire form of `browser.action_request`.
nonisolated private struct ActionRequestEvent: Decodable {
  let type: String?
  let actionID: String
  let action: String
  let args: [String: AgentJSONValue]

  enum CodingKeys: String, CodingKey {
    case type
    case actionID = "action_id"
    case action
    case args
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decodeIfPresent(String.self, forKey: .type)
    actionID = try container.decode(String.self, forKey: .actionID)
    action = try container.decode(String.self, forKey: .action)
    args = try container.decodeIfPresent([String: AgentJSONValue].self, forKey: .args) ?? [:]
  }
}

/// What the relay posts back as the action's `result`:
/// `{"ok": Bool, "error"?: String, "data"?: {...}, "data_url"?: String}`.
nonisolated public struct AgentBrowserActionResult: Sendable, Hashable, Encodable {
  /// Whether the action succeeded.
  public let ok: Bool
  /// Why it failed.
  public let error: String?
  /// Action data, for example the snapshot tree or the final URL. Empty data is not sent.
  public let data: [String: AgentJSONValue]
  /// `screenshot` only: "data:image/png;base64,...".
  public let dataURL: String?

  enum CodingKeys: String, CodingKey {
    case ok
    case error
    case data
    case dataURL = "data_url"
  }

  /// Creates a result.
  public init(
    ok: Bool, error: String? = nil, data: [String: AgentJSONValue] = [:], dataURL: String? = nil
  ) {
    self.ok = ok
    self.error = error
    self.data = data
    self.dataURL = dataURL
  }

  /// A success, with optional data.
  public static func success(_ data: [String: AgentJSONValue] = [:], dataURL: String? = nil)
    -> Self
  {
    Self(ok: true, data: data, dataURL: dataURL)
  }

  /// A failure.
  public static func failure(_ message: String) -> Self {
    Self(ok: false, error: message)
  }

  /// Omits absent keys, as the Electron relay does.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ok, forKey: .ok)
    try container.encodeIfPresent(error, forKey: .error)
    if !data.isEmpty {
      try container.encode(data, forKey: .data)
    }
    try container.encodeIfPresent(dataURL, forKey: .dataURL)
  }

  /// The JSON body to post.
  public func jsonData() throws(BrowserError) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      return try encoder.encode(self)
    } catch {
      throw .agentActionFailed("Encoding the action result failed: \(error)")
    }
  }

  /// A copy with `extra` merged into `data`.
  func merging(_ extra: [String: AgentJSONValue]) -> Self {
    guard !extra.isEmpty else { return self }
    var merged = data
    merged.merge(extra) { _, new in new }
    return Self(ok: ok, error: error, data: merged, dataURL: dataURL)
  }
}
