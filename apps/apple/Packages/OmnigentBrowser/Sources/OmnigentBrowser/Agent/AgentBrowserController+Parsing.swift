internal import Foundation

/// A validated agent action. Validation follows `buildBrowserActionScript` in
/// `web/electron/src/browserActionScript.mjs`: unknown keys are rejected, refs are positive
/// integers, selectors at most 4096 characters, snapshot IDs 128, text 100 000.
nonisolated enum AgentAction: Sendable, Hashable {
  case navigate(URL)
  case snapshot
  case click(AgentElementTarget)
  case type(AgentElementTarget, text: String)
  case press(BrowserAgentKey, BrowserAgentModifiers, AgentElementTarget?)
  case scroll(deltaX: Double, deltaY: Double, AgentElementTarget?)
  case evaluate(String)
  case waitForLoad(timeout: Duration?)
  case screenshot

  private static let targetKeys = ["ref", "snapshot_id", "selector"]

  typealias Args = [String: AgentJSONValue]

  /// Allowed argument keys and the parser, per action name.
  private static let grammar:
    [String: (keys: [String], parse: @Sendable (Args) throws(BrowserError) -> Self)] = [
      "navigate": (["url"], { args throws(BrowserError) in .navigate(try url(args)) }),
      "snapshot": ([], { _ in .snapshot }),
      "screenshot": ([], { _ in .screenshot }),
      "click": (targetKeys, { args throws(BrowserError) in .click(try requiredTarget(args)) }),
      "type": (targetKeys + ["text"], { args throws(BrowserError) in try typeAction(args) }),
      "press": (
        targetKeys + ["key", "modifiers"], { args throws(BrowserError) in try press(args) }
      ),
      "scroll": (
        targetKeys + ["delta_x", "delta_y"], { args throws(BrowserError) in try scroll(args) }
      ),
      "evaluate": (
        ["expression"],
        { args throws(BrowserError) in
          .evaluate(try string(args, "expression", maxLength: 100_000, required: true) ?? "")
        }
      ),
      "wait_for_load": (
        ["timeout_ms"], { args throws(BrowserError) in .waitForLoad(timeout: try timeout(args)) }
      ),
    ]

  /// Parses `action` and `args`; the error text is what the agent sees.
  init(action: String, args: Args) throws(BrowserError) {
    guard let entry = Self.grammar[action] else {
      throw .agentActionFailed("Unknown browser action: \(action)")
    }
    if let unknown = args.keys.sorted().first(where: { !entry.keys.contains($0) }) {
      throw .agentActionFailed("Unsupported argument \"\(unknown)\" for browser action \(action)")
    }
    self = try entry.parse(args)
  }

  private static func typeAction(_ args: Args) throws(BrowserError) -> Self {
    let text = try string(args, "text", maxLength: 100_000, required: true) ?? ""
    return .type(try requiredTarget(args), text: text)
  }

  private static func url(_ args: [String: AgentJSONValue]) throws(BrowserError) -> URL {
    guard let text = try string(args, "url", maxLength: 8192, required: true), !text.isEmpty,
      let url = URL(string: text), url.scheme != nil
    else {
      throw .agentActionFailed("url is required and must be an absolute URL")
    }
    return url
  }

  private static func string(
    _ args: [String: AgentJSONValue], _ key: String, maxLength: Int, required: Bool
  ) throws(BrowserError) -> String? {
    guard let value = args[key] else {
      if required { throw .agentActionFailed("\(key) is required") }
      return nil
    }
    guard case .string(let text) = value, text.count <= maxLength else {
      throw .agentActionFailed("\(key) must be a string of at most \(maxLength) characters")
    }
    return text
  }

  private static func number(_ args: [String: AgentJSONValue], _ key: String)
    throws(BrowserError) -> Double?
  {
    guard let value = args[key] else { return nil }
    guard case .number(let number) = value, number.isFinite else {
      throw .agentActionFailed("\(key) must be a number")
    }
    return number
  }

  /// The target, when the args name one. A ref wins over a selector, as on the desktop app.
  static func target(_ args: [String: AgentJSONValue]) throws(BrowserError) -> AgentElementTarget? {
    let snapshotID = try string(args, "snapshot_id", maxLength: 128, required: false)
    if let ref = args["ref"] {
      guard case .number(let number) = ref, number.rounded() == number, number > 0,
        number <= 9_007_199_254_740_991
      else {
        throw .agentActionFailed("ref must be a positive integer")
      }
      return .ref(Int(number), snapshotID: snapshotID)
    }
    if let selector = try string(args, "selector", maxLength: 4096, required: false) {
      guard !selector.isEmpty else { throw .agentActionFailed("A ref or selector is required") }
      return .selector(selector)
    }
    return nil
  }

  private static func requiredTarget(_ args: [String: AgentJSONValue]) throws(BrowserError)
    -> AgentElementTarget
  {
    guard let target = try target(args) else {
      throw .agentActionFailed("A ref or selector is required")
    }
    return target
  }

  private static func press(_ args: [String: AgentJSONValue]) throws(BrowserError) -> Self {
    let name = try string(args, "key", maxLength: 64, required: true) ?? ""
    guard let key = BrowserAgentKey(name: name) else {
      throw .agentActionFailed("Unknown key \"\(name)\"")
    }
    var names: [String] = []
    if let value = args["modifiers"] {
      guard case .array(let items) = value else {
        throw .agentActionFailed("modifiers must be an array of strings")
      }
      for item in items {
        guard case .string(let modifier) = item else {
          throw .agentActionFailed("modifiers must be an array of strings")
        }
        names.append(modifier)
      }
    }
    guard let modifiers = BrowserAgentModifiers(names: names) else {
      throw .agentActionFailed("Unknown modifier in \(names); use Shift, Control, Alt or Meta")
    }
    return .press(key, modifiers, try target(args))
  }

  private static func scroll(_ args: [String: AgentJSONValue]) throws(BrowserError) -> Self {
    let deltaX = try number(args, "delta_x")
    let deltaY = try number(args, "delta_y")
    guard deltaX != nil || deltaY != nil else {
      throw .agentActionFailed("scroll needs delta_x or delta_y")
    }
    return .scroll(deltaX: deltaX ?? 0, deltaY: deltaY ?? 0, try target(args))
  }

  private static func timeout(_ args: [String: AgentJSONValue]) throws(BrowserError) -> Duration? {
    guard let milliseconds = try number(args, "timeout_ms") else { return nil }
    guard milliseconds > 0 else { throw .agentActionFailed("timeout_ms must be positive") }
    return .milliseconds(Int(milliseconds))
  }
}
