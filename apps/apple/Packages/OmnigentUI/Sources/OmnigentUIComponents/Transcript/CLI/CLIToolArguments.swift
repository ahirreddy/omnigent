import Foundation

/// A tool call's arguments as the core records them for display: one `key: value` line per
/// field, keys sorted, a nested list's entries on the lines that follow. JSON arguments read
/// the same way.
nonisolated struct CLIToolArguments: Hashable, Sendable {
  /// A field: its key, and its value with any lines that continue it.
  struct Field: Hashable, Sendable {
    var key: String
    var value: String
  }

  /// The top-level fields, in order.
  let fields: [Field]
  /// The arguments when they have no fields: a bare command, path or query.
  let bare: String
  private let text: String

  init(_ arguments: String) {
    let object = ToolTitle.object(arguments)
    guard object.isEmpty else {
      fields = object.keys.sorted().map { Field(key: $0, value: Self.display(object[$0] ?? "")) }
      text = fields.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
      bare = ""
      return
    }
    text = arguments
    let pairs = Self.pairs(text[...])
    // Keys come sorted, so a line whose key does not sort later continues the last value.
    fields = pairs.reduce(into: []) { fields, pair in
      if let last = fields.last, pair.key <= last.key {
        fields[fields.count - 1].value += "\n\(pair.key): \(pair.value)"
      } else {
        fields.append(pair)
      }
    }
    bare = pairs.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
  }

  /// The value of the first of `keys` that has one.
  func value(_ keys: [String]) -> String? {
    keys.lazy.compactMap { key in fields.first { $0.key == key }?.value }.first { !$0.isEmpty }
  }

  /// The objects listed under `key`: each starts where the sorted keys start over.
  func items(_ key: String) -> [[String: String]] {
    let marker = "\(key): "
    // The key opens a line: the text's first, or a later one.
    guard let open = text.range(of: text.hasPrefix(marker) ? marker : "\n" + marker)
    else { return [] }
    var items: [[Field]] = []
    for pair in Self.pairs(text[open.upperBound...]) {
      if let last = items.last?.last, pair.key > last.key {
        items[items.count - 1].append(pair)
      } else {
        items.append([pair])
      }
    }
    return items.map { item in Dictionary(item.map { ($0.key, $0.value) }) { first, _ in first } }
  }

  /// The `key: value` lines of `text`; a line that is not one continues the value before it.
  private static func pairs(_ text: Substring) -> [Field] {
    let line = /(?<key>[A-Za-z_\-][A-Za-z0-9_.\-]*): (?<value>.*)/
    var pairs: [Field] = []
    for row in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if let match = row.wholeMatch(of: line) {
        pairs.append(Field(key: String(match.key), value: String(match.value)))
      } else if !pairs.isEmpty {
        pairs[pairs.count - 1].value += "\n\(row)"
      }
    }
    return pairs
  }

  /// A JSON value as the core's display text writes it.
  private static func display(_ value: Any) -> String {
    switch value {
    case let text as String: text
    case let list as [Any]: list.map(display).joined(separator: "\n")
    case let object as [String: Any]:
      object.keys.sorted().map { "\($0): \(display(object[$0] ?? ""))" }.joined(separator: "\n")
    default: value is NSNull ? "" : "\(value)"
    }
  }
}
