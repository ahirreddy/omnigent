import Foundation

public struct SessionEventSection: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public var title: String
  public var summary: String
  public var details: [ConversationDetailSection]
  public var sessionID: String?

  public init(
    id: String, title: String, summary: String,
    details: [ConversationDetailSection] = [], sessionID: String? = nil
  ) {
    self.id = id
    self.title = title
    self.summary = summary
    self.details = details
    self.sessionID = sessionID
  }
}

/// Snapshot-backed fields merge sparsely; full-list events replace their own field.
public struct SessionEventState: Codable, Equatable, Sendable {
  var values: [String: JSONValue] = [:]
  public var supersededSessionID: String? { values["superseded"]?.string }

  public init() {}

  init(snapshot: [String: JSONValue]) {
    for key in [
      "context_window", "total_cost_usd", "usage_by_model", "todos", "skills",
      "terminal_pending", "sandbox_status", "mcp_startup", "collaboration_mode", "status",
    ] {
      if let value = snapshot[key] { values[key] = value }
    }
    if let value = snapshot["last_total_tokens"] { values["context_tokens"] = value }
    if let mode = snapshot["labels"]?.object?["omnigent.codex_native.collaboration_mode"] {
      values["collaboration_mode"] = mode
    }
  }

  mutating func merge(_ newer: SessionEventState?) {
    guard let newer else { return }
    values.merge(newer.values) { _, new in new }
  }

  mutating func set(_ key: String, _ value: JSONValue?) {
    if let value { values[key] = value }
  }

  mutating func updateRecord(_ key: String, id: String, value: JSONValue?) {
    guard !id.isEmpty else { return }
    var records = values[key]?.object ?? [:]
    records[id] = value
    // Bound non-durable metadata even for very long sessions.
    if records.count > 500 { records.removeValue(forKey: records.keys.sorted().first!) }
    values[key] = .object(records)
  }

  public var sections: [SessionEventSection] {
    var result: [SessionEventSection] = []
    func detail(_ id: String, _ title: String, _ text: String) -> ConversationDetailSection {
      .init(id: id, title: title, text: String(text.prefix(16_384)))
    }
    if let status = values["status"]?.string {
      let count = values["background_task_count"]?.int
      result.append(
        .init(
          id: "status", title: "Session", summary: status.capitalized,
          details: count.map { [detail("background", "Background tasks", String($0))] } ?? []))
    }
    if let mode = values["collaboration_mode"]?.string {
      result.append(
        .init(id: "collaboration", title: "Collaboration mode", summary: mode.capitalized))
    }
    let usageKeys = ["context_tokens", "context_window", "total_cost_usd", "usage_by_model"]
    let usageDetails = usageKeys.compactMap { key -> ConversationDetailSection? in
      guard let value = values[key], value != .null else { return nil }
      let labels = [
        "context_tokens": "Context tokens", "context_window": "Context window",
        "total_cost_usd": "Total cost (USD)", "usage_by_model": "Usage by model",
      ]
      return detail(key, labels[key]!, value.safeDisplayText)
    }
    if !usageDetails.isEmpty {
      let fill = values["context_tokens"]?.int.map { "\($0) context tokens" } ?? "Reported usage"
      result.append(.init(id: "usage", title: "Usage", summary: fill, details: usageDetails))
    }
    if let todos = values["todos"]?.array {
      let completed = todos.filter { $0.object?["status"]?.string == "completed" }.count
      result.append(
        .init(
          id: "todos", title: "Tasks", summary: "\(completed) of \(todos.count) complete",
          details: todos.prefix(500).enumerated().compactMap { index, item in
            guard let task = item.object, let content = task["content"]?.string else { return nil }
            let status = task["status"]?.string ?? "pending"
            let active = task["activeForm"]?.string
            return detail(
              "todo-\(index)",
              "\(status.replacingOccurrences(of: "_", with: " ").capitalized): \(content)",
              status == "in_progress" ? (active ?? content) : content)
          }))
    }
    if let pending = values["terminal_pending"]?.bool, pending {
      result.append(.init(id: "terminal-pending", title: "Terminal", summary: "Starting terminal…"))
    }
    if let sandbox = values["sandbox_status"]?.object {
      result.append(
        .init(
          id: "sandbox", title: "Environment startup",
          summary: (sandbox["stage"]?.string ?? "Unknown").capitalized,
          details: sandbox["error"]?.string.map { [detail("error", "Error", $0)] } ?? []))
    }
    if let servers = values["mcp_startup"]?.object, !servers.isEmpty {
      result.append(
        .init(
          id: "mcp", title: "MCP servers", summary: "\(servers.count) servers",
          details: servers.keys.sorted().prefix(500).map { name in
            let server = servers[name]?.object ?? [:]
            let text = [server["status"]?.string, server["error"]?.string].compactMap { $0 }.joined(
              separator: "\n")
            return detail(name, name, text)
          }))
    }
    if let skills = values["skills"]?.array {
      result.append(
        .init(
          id: "skills", title: "Skills", summary: "\(skills.count) available",
          details: skills.prefix(500).enumerated().map { index, value in
            let skill = value.object ?? [:]
            return detail(
              "skill-\(index)", skill["name"]?.string ?? "Skill",
              skill["description"]?.string ?? "No description reported")
          }))
    }
    if let viewers = values["viewers"]?.array {
      result.append(
        .init(
          id: "presence", title: "Viewers", summary: "\(viewers.count) connected",
          details: viewers.prefix(500).enumerated().map { index, value in
            let viewer = value.object ?? [:]
            return detail(
              "viewer-\(index)", viewer["user_id"]?.string ?? "Viewer",
              viewer["idle"]?.bool == true ? "Idle" : "Active")
          }))
    }
    if let resources = values["resources"]?.object {
      for id in resources.keys.sorted() {
        let resource = resources[id]?.object ?? [:]
        let type = resource["type"]?.string ?? "Resource"
        let active = values["terminal_activity"]?.object?[id]?.bool == true
        let metadata = resource["metadata"]?.object ?? [:]
        let details = ["cwd", "command", "path", "description", "environment"].compactMap {
          key -> ConversationDetailSection? in
          guard let value = metadata[key] else { return nil }
          return detail(key, key.capitalized, value.safeDisplayText)
        }
        result.append(
          .init(
            id: "resource-\(id)", title: resource["name"]?.string ?? type.capitalized,
            summary: active ? "Terminal output received" : type.capitalized,
            details: [detail("id", "Resource ID", id)] + details))
      }
    }
    if let children = values["children"]?.object {
      for id in children.keys.sorted() {
        let child = children[id]?.object ?? [:]
        result.append(
          .init(
            id: "child-\(id)",
            title: child["title"]?.string ?? child["agent_name"]?.string ?? "Subagent",
            summary: child["status"]?.string ?? "Created",
            details: [detail("id", "Session ID", id)], sessionID: id))
      }
    }
    if let environments = values["changed_files"]?.object {
      for id in environments.keys.sorted() {
        let entry = environments[id]?.object ?? [:]
        let files = entry["entries"]?.array ?? entry["files"]?.array ?? entry["data"]?.array ?? []
        let error = entry["error"]?.string
        result.append(
          .init(
            id: "files-\(id)", title: "Changed files",
            summary: error ?? "\(files.count) files in \(id)",
            details: files.prefix(500).enumerated().map { index, file in
              let item = file.object ?? [:]
              return detail(
                "file-\(index)", item["path"]?.string ?? item["name"]?.string ?? "File",
                item["status"]?.string ?? file.safeDisplayText)
            }))
      }
    }
    if let target = supersededSessionID {
      result.append(
        .init(
          id: "superseded", title: "Session continued elsewhere",
          summary: "Open the new session. Your draft stays in this conversation.", sessionID: target
        ))
    }
    return result
  }
}
