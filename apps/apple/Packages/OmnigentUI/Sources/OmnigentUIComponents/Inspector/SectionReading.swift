import Foundation

/// Reads the core's `EventSection`s (`reducer::presentation::sections`) by their stable ids.
/// Only display parsing lives here; the sections are built by the core.
nonisolated enum SectionReading {
  enum TodoState: Hashable {
    case pending
    case inProgress
    case completed
  }

  struct Todo: Hashable, Identifiable {
    let id: String
    let state: TodoState
    let text: String
  }

  struct Usage: Hashable {
    var contextTokens: Int?
    var contextWindow: Int?
    var totalCost: Double?
    var byModel: [String]

    var fraction: Double? {
      guard let contextTokens, let contextWindow, contextWindow > 0 else { return nil }
      return min(1, Double(contextTokens) / Double(contextWindow))
    }
  }

  struct ChangedFile: Hashable, Identifiable {
    let path: String
    let status: String
    var id: String { path }

    /// A one-letter status, like `git status --short`.
    var letter: String {
      switch status.lowercased() {
      case "added", "new", "created", "untracked": "A"
      case "deleted", "removed": "D"
      case "renamed": "R"
      case "modified", "changed", "updated": "M"
      default: String(status.prefix(1)).uppercased()
      }
    }
  }

  /// Todos from the `todos` section, whose detail titles read `<Status>: <content>`.
  static func todos(_ section: EventSection) -> [Todo] {
    section.details.map { detail in
      let prefix = detail.title.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
      let state: TodoState =
        switch prefix.lowercased() {
        case "completed": .completed
        case "in progress": .inProgress
        default: .pending
        }
      return Todo(id: detail.id, state: state, text: detail.text)
    }
  }

  static func usage(_ section: EventSection) -> Usage {
    func detail(_ id: String) -> String? { section.details.first { $0.id == id }?.text }
    return Usage(
      contextTokens: detail("context_tokens").flatMap { Int($0) },
      contextWindow: detail("context_window").flatMap { Int($0) },
      totalCost: detail("total_cost_usd").flatMap { Double($0) },
      byModel: detail("usage_by_model")?.split(separator: "\n").map(String.init) ?? [])
  }

  static func changedFiles(_ section: EventSection) -> [ChangedFile] {
    section.details.map { ChangedFile(path: $0.title, status: $0.text) }
  }

  struct Viewer: Hashable, Identifiable {
    let id: String
    let name: String
    let isIdle: Bool

    var initials: String {
      let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" || $0 == "_" })
      return parts.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
  }

  static func viewers(_ section: EventSection) -> [Viewer] {
    section.details.map { Viewer(id: $0.id, name: $0.title, isIdle: $0.text == "Idle") }
  }
}
